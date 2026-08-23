#!/bin/bash
# Set variables

echo ""

# Ensure HOME is set properly
export HOME="/home/ec2-user"

# Update dependencies
sudo yum update -y
sudo yum install -y docker git jq -y

# ---------------------------------------------------------------------------
# Fetch the true secrets at boot from Secrets Manager through the instance role.
#
# They are NOT interpolated into user_data by Terraform. Rendered user_data is
# readable by any process on the box through the instance metadata service, and
# it is stored verbatim in the Terraform state file. A secret templated in is a
# secret published twice. Terraform therefore passes only the secret NAME.
# ---------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --secret-id "${secret_name}" \
  --region us-east-1 \
  --query SecretString --output text 2>>/tmp/git-clone-setup.log)"

# Fail fast. An empty or None fetch means the instance role lacks
# GetSecretValue, the region is wrong, or IMDS is blocked. Do not fall through
# into a stack that boots with blank passwords and an empty deploy key. Abort so
# the failure is loud instead of silently broken.
if [ -z "$SECRET_JSON" ] || [ "$SECRET_JSON" = "None" ]; then
  echo "FATAL: could not fetch ${secret_name} from Secrets Manager (instance role missing GetSecretValue?)" >> /tmp/git-clone-setup.log
  exit 1
fi

GRAFANA_ADMIN_PASSWORD="$(printf '%s' "$SECRET_JSON" | jq -r '.default_grafana_admin_password')"
DEFAULT_ADMIN_PASSWORD="$(printf '%s' "$SECRET_JSON" | jq -r '.default_admin_password')"
DEFAULT_MEMBER_PASSWORD="$(printf '%s' "$SECRET_JSON" | jq -r '.default_member_password')"

# Guard: every key must be present and non-empty. A missing key otherwise yields
# a Grafana with a blank admin password. Never echo a value here -- report only
# which position failed.
_i=0
for _v in "$GRAFANA_ADMIN_PASSWORD" "$DEFAULT_ADMIN_PASSWORD" "$DEFAULT_MEMBER_PASSWORD"; do
  _i=$((_i + 1))
  if [ -z "$_v" ] || [ "$_v" = "null" ]; then
    echo "FATAL: required secret key #$_i was empty or null in ${secret_name}" >> /tmp/git-clone-setup.log
    exit 1
  fi
done
unset _v _i
# Drop the bundle now that the three values are extracted.
unset SECRET_JSON

# Install docker-compose
sudo curl -L https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m) -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Start docker service and the ec2-user to the docker group
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -a -G docker ec2-user

# Install Docker Buildx 0.17+ (required for docker-compose build)
# The default buildx on Amazon Linux 2023 is too old (0.12.x)
export BUILDX_VERSION="v0.17.1"
sudo mkdir -p /usr/local/lib/docker/cli-plugins
sudo curl -SL "https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION.linux-amd64" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
echo "Installed buildx $(docker buildx version)" >> /tmp/git-clone-setup.log

# -----------------------------------------------------------------------------
# Fetch the stack from S3. NO GIT CREDENTIAL ON THE BOX.
#
# This replaces an SSH-deploy-key + git-clone boot. CI publishes the archive to
# the bootstrap bucket (.github/workflows/publish-bootstrap.yml); the pull
# authenticates with the instance role over the free same-VPC S3 gateway
# endpoint. No durable secret is written to disk, so none can leak from it.
#
# Integrity is verified FAIL-CLOSED. A checksum mismatch refuses to extract
# rather than booting a stack of unknown provenance. CI uploads the checksum
# BEFORE the archive, so a boot that reads mid-publish compares a new archive
# against an old checksum, fails, and simply retries on the next boot.
# -----------------------------------------------------------------------------
BOOTSTRAP_BUCKET="${bootstrap_bucket}"
echo "Fetching stack archive from s3://$BOOTSTRAP_BUCKET/ ..." >> /tmp/git-clone-setup.log
sudo -u ec2-user mkdir -p /home/ec2-user/lgtm_stack
aws s3 cp "s3://$BOOTSTRAP_BUCKET/lgtm_stack.sha256" /tmp/lgtm_stack.sha256 >> /tmp/git-clone-setup.log 2>&1
aws s3 cp "s3://$BOOTSTRAP_BUCKET/lgtm_stack.tar.gz"  /tmp/lgtm_stack.tar.gz  >> /tmp/git-clone-setup.log 2>&1
if echo "$(cat /tmp/lgtm_stack.sha256)  /tmp/lgtm_stack.tar.gz" | sha256sum -c - >> /tmp/git-clone-setup.log 2>&1; then
  sudo -u ec2-user tar -xzf /tmp/lgtm_stack.tar.gz -C /home/ec2-user/lgtm_stack >> /tmp/git-clone-setup.log 2>&1
  CLONE_RESULT=$?
  rm -f /tmp/lgtm_stack.tar.gz /tmp/lgtm_stack.sha256
else
  echo "FATAL: bootstrap archive checksum mismatch - refusing to extract (tampering or a partial download)" >> /tmp/git-clone-setup.log
  CLONE_RESULT=1
fi
cd /home/ec2-user
echo "Stack fetch exit code: $CLONE_RESULT" >> /tmp/git-clone-setup.log

# Start services if the archive extracted cleanly
if [ $CLONE_RESULT -eq 0 ]; then
  cd /home/ec2-user/lgtm_stack

  # Create .env. Non-secret config goes in through a QUOTED heredoc: Terraform
  # renders the placeholders below to literals, and the quoted heredoc then
  # stops the shell from re-expanding a stray dollar sign in a value.
  cat > /home/ec2-user/lgtm_stack/.env <<'ENVEOF'
DOMAIN_NAME=${domain_name}
GRAFANA_ROOT_URL=https://${domain_name}
CERTBOT_EMAIL=${certbot_email}
CERTBOT_STAGING=0
ENVEOF
  # Append the 3 boot-fetched secrets, shell-expanded and never templated.
  {
    echo "GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD"
    echo "DEFAULT_ADMIN_PASSWORD=$DEFAULT_ADMIN_PASSWORD"
    echo "DEFAULT_MEMBER_PASSWORD=$DEFAULT_MEMBER_PASSWORD"
  } >> /home/ec2-user/lgtm_stack/.env
  chown ec2-user:ec2-user /home/ec2-user/lgtm_stack/.env
  chmod 600 /home/ec2-user/lgtm_stack/.env
  echo ".env file created with Grafana secrets and SSL config" >> /tmp/git-clone-setup.log

  # Seed the HTTP-only nginx config into the host conf.d BEFORE compose starts.
  # nginx bind-mounts that directory, so it must be populated or nginx starts
  # with no server block and the ACME challenge cannot be served.
  sudo -u ec2-user bash scripts/render-nginx-ssl.sh init >> /tmp/git-clone-setup.log 2>&1

  # Run docker-compose with SSL profile enabled
  echo "Starting docker-compose with SSL profile..." >> /tmp/git-clone-setup.log
  docker-compose --profile ssl up -d >> /tmp/git-clone-setup.log 2>&1
  COMPOSE_RESULT=$?

  if [ $COMPOSE_RESULT -eq 0 ]; then
    echo "Services started successfully" >> /tmp/git-clone-setup.log

    # Wait for services to stabilize and log status
    sleep 30
    echo "Container status after 30s:" >> /tmp/git-clone-setup.log
    docker ps >> /tmp/git-clone-setup.log 2>&1

    # Obtain SSL certificate from Let's Encrypt
    echo "Obtaining SSL certificate from Let's Encrypt..." >> /tmp/git-clone-setup.log
    docker exec certbot certbot certonly \
      --webroot -w /var/www/certbot \
      -d ${domain_name} \
      --email ${certbot_email} \
      --agree-tos --no-eff-email \
      --non-interactive >> /tmp/git-clone-setup.log 2>&1
    CERTBOT_RESULT=$?

    if [ $CERTBOT_RESULT -eq 0 ]; then
      echo "SSL certificate obtained successfully" >> /tmp/git-clone-setup.log

      # Render the SSL server config ON THE HOST, into the bind-mounted conf.d.
      # The script tests the config and only reloads nginx if it passes, so a bad
      # render leaves the working HTTP-only config live rather than breaking the
      # server. Rendering on the host means a container recreate does not revert it.
      echo "Generating SSL-enabled NGINX configuration..." >> /tmp/git-clone-setup.log
      if sudo -u ec2-user bash scripts/render-nginx-ssl.sh ssl "${domain_name}" >> /tmp/git-clone-setup.log 2>&1; then
        echo "NGINX reloaded with SSL configuration" >> /tmp/git-clone-setup.log
        echo "Grafana is now available at: https://${domain_name}" >> /tmp/git-clone-setup.log
      else
        echo "SSL render or nginx test failed - keeping HTTP-only config" >> /tmp/git-clone-setup.log
      fi
    else
      echo "Failed to obtain SSL certificate (exit code: $CERTBOT_RESULT)" >> /tmp/git-clone-setup.log
      echo "Grafana remains accessible via HTTP at port 80" >> /tmp/git-clone-setup.log
    fi

    # ==========================================================================
    # CloudWatch Agent Installation and Configuration
    # ==========================================================================
    echo "Installing CloudWatch Agent..." >> /tmp/git-clone-setup.log

    # Install CloudWatch Agent
    sudo yum install -y amazon-cloudwatch-agent >> /tmp/git-clone-setup.log 2>&1

    # Copy CloudWatch agent config from repository
    sudo cp /home/ec2-user/lgtm_stack/config/cloudwatch-agent-config.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

    # Start CloudWatch Agent with the configuration
    sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -s \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json >> /tmp/git-clone-setup.log 2>&1

    CW_RESULT=$?
    if [ $CW_RESULT -eq 0 ]; then
      echo "CloudWatch Agent started successfully" >> /tmp/git-clone-setup.log
    else
      echo "CloudWatch Agent failed to start (exit code: $CW_RESULT)" >> /tmp/git-clone-setup.log
    fi

    # Enable CloudWatch Agent to start on boot
    sudo systemctl enable amazon-cloudwatch-agent >> /tmp/git-clone-setup.log 2>&1

  else
    echo "docker-compose failed with exit code: $COMPOSE_RESULT" >> /tmp/git-clone-setup.log
    echo "Docker version info:" >> /tmp/git-clone-setup.log
    docker --version >> /tmp/git-clone-setup.log 2>&1
    docker-compose version >> /tmp/git-clone-setup.log 2>&1
    docker buildx version >> /tmp/git-clone-setup.log 2>&1
  fi
else
  echo "Failed to fetch or verify the stack archive - services not started" >> /tmp/git-clone-setup.log
fi