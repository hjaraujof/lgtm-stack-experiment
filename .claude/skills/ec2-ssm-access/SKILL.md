---
name: ec2-ssm-access
description: Reach the deployed EC2 LGTM host through AWS Systems Manager - find the instance id, check the SSM agent, open a session, or run send-command recipes for container status, logs, certificates and restarts. Use when troubleshooting the EC2 stack; SSH is closed.
---

# EC2 access through AWS Systems Manager (SSM)

SSH (port 22) is closed in `main.tf`. SSM Session Manager needs no inbound port and is the routine way onto the box. The instance role carries `AmazonSSMManagedInstanceCore`.

**Prerequisites:**
- AWS CLI configured with credentials for the account
- The instance is running and its SSM agent is online
- The Session Manager plugin is installed (for interactive sessions)

**Install the Session Manager plugin (one-time):**

```bash
# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb

# Verify installation
session-manager-plugin --version
```

## 1. Get the instance id from the state

```bash
tofu show -json | jq -r '.values.root_module.resources[] | select(.type == "aws_instance") | .values.id'
```

The repo uses OpenTofu (`.terraform.lock.hcl` pins `registry.opentofu.org`), so run `tofu`, not `terraform`.

## 2. Check that the SSM agent is online

```bash
INSTANCE_ID="i-0123456789abcdef0"  # replace with the real id
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[*].{InstanceId:InstanceId,PingStatus:PingStatus}' \
  --output table
```

## 3. Connect interactively

```bash
aws ssm start-session --target "$INSTANCE_ID"

# The session shell is ssm-user. Switch to ec2-user for the stack's environment
sudo su - ec2-user
cd ~/lgtm_stack

# EC2 runs the standalone docker-compose binary (hyphen) with the ssl profile
docker-compose --profile ssl ps
docker-compose --profile ssl logs -f nginx
```

## 4. Run commands without a session

```bash
# Check container status
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl ps"]' \
  --output json --query 'Command.CommandId'

# Get the output (replace COMMAND_ID with the returned id)
aws ssm get-command-invocation \
  --command-id "COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json
```

## 5. Common send-command payloads

```bash
# Setup log
commands=["tail -100 /tmp/git-clone-setup.log"]

# All container status with the SSL profile
commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl ps"]

# One service's logs
commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl logs nginx --tail 50"]

# Certificate status
commands=["docker exec certbot certbot certificates"]

# Obtain a certificate by hand
commands=["docker exec certbot certbot certonly --webroot -w /var/www/certbot -d grafana.example.com --email devops@example.com --agree-tos --no-eff-email --non-interactive"]

# Render the SSL config and reload nginx. Run it as ec2-user, as user_data.tpl does,
# so the rendered file in config/nginx/conf.d/ is not left owned by root
commands=["cd /home/ec2-user/lgtm_stack && sudo -u ec2-user bash scripts/render-nginx-ssl.sh ssl grafana.example.com"]

# Restart the whole stack
commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl down && docker-compose --profile ssl up -d"]
```

## Notes

- `send-command` runs as root, and an interactive `start-session` shell runs as `ssm-user`. Neither is ec2-user. Set `export HOME=/home/ec2-user` in a one-shot command if a tool needs it.
- `~/lgtm_stack` is a `git archive` extract with no `.git` directory, so git fails there for every user. The instance fetches the archive from the S3 bootstrap bucket only at boot (`bootstrap.tf`, `.github/workflows/publish-bootstrap.yml`).
- A file changed inside a container is lost when the container is recreated, unless it sits on a volume.
- `grafana.example.com` and `devops@example.com` are placeholders.
