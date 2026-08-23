# LGTM Local Stack

**Repository Type:** Infrastructure Tooling
**Purpose:** LGTM (Loki, Grafana, Tempo, Mimir) observability stack for local development and AWS deployment

---

## CRITICAL: Session Start Protocol

**At the start of EVERY session:**
1. **Query memory** for related facts, patterns, and previous work
2. **Review available agents** below and invoke specialized agents when appropriate
3. **Follow global guidance** in your organization-wide CLAUDE.md for organization-wide patterns

---

## CRITICAL: Troubleshooting Environment Clarification

**When troubleshooting issues, ALWAYS use the `AskUserQuestion` tool to ask first:**

> "Are we troubleshooting the **local development** stack or the **deployed EC2 instance**?"

**MANDATORY**: Use the `AskUserQuestion` tool for all clarifying questions and multiple-choice decisions. Do not ask questions inline in text responses.

**Why this matters:**
- Commands and access methods differ significantly between environments
- Local uses `docker compose` directly; EC2 requires SSH access
- Local accesses Grafana at `localhost:3000`; EC2 uses `grafana.example.com`
- NGINX/SSL is only active on EC2 (unless using `--profile ssl` locally)
- Network paths, DNS resolution, and security groups only apply to EC2

**Environment-specific approaches:**

| Aspect | Local | EC2 |
|--------|-------|-----|
| **Access** | Direct `docker compose` commands | SSH or SSM (see Troubleshooting section) |
| **Docker command** | `docker compose` (space) | `docker-compose` (hyphen) |
| **Grafana URL** | `http://localhost:3000` | `https://grafana.example.com` |
| **Logs** | `docker compose logs <service>` | SSH/SSM + `docker-compose logs` |
| **NGINX/SSL** | Optional (profile) | Always active |
| **Network issues** | Usually container networking | Security groups, DNS, VPC |

---

## Quick Start

### Local Development

```bash
# Start the entire LGTM stack locally
docker compose up -d

# Stop the stack
docker compose down

# View logs for all services
docker compose logs -f

# View logs for specific service
docker compose logs -f grafana
docker compose logs -f tempo
docker compose logs -f loki
docker compose logs -f mimir
docker compose logs -f otel-collector

# Rebuild and restart services
docker compose up -d --build

# Clean up all data volumes (destructive)
sudo rm -rf ./data/*
```

### AWS Deployment (Terraform)

```bash
terraform init      # Initialize Terraform
terraform plan      # Plan deployment
terraform apply     # Apply infrastructure changes
terraform destroy   # Destroy infrastructure
terraform show      # View current state
```

---

## Stack Overview

### Components

| Component | Port | Purpose |
|-----------|------|---------|
| **Loki** | 3100 | Log aggregation system |
| **Grafana** | 3000 | Visualization dashboard (see credentials below) |
| **Tempo** | 3200 | Distributed tracing backend |
| **Mimir** | 9009 | Prometheus-compatible metrics backend |
| **OTel Collector** | 4317/4318 | OTLP receiver (gRPC/HTTP) |
| **NGINX** | 80/443 | SSL termination reverse proxy (AWS only) |
| **Certbot** | - | Let's Encrypt certificate management (AWS only) |

### Data Flow

```text
Application --> OTel Collector (OTLP) --> {Loki, Tempo, Mimir} --> Grafana
```

### Current Status

- Stack requires ~15 seconds for full readiness after startup
- All services pass health checks after initial stabilization
- Grafana successfully connects to all datasources
- OTLP endpoints ready for application telemetry data

---

## Architecture

### Project Structure

```
lgtm-stack-experiment/
├── config/
│   ├── grafana/
│   │   ├── users-config.json           # Default users and team configuration
│   │   └── provisioning/
│   │       └── datasources/
│   │           └── datasources.yaml    # Pre-configured Grafana datasources
│   ├── nginx/
│   │   ├── nginx.conf                  # Main NGINX configuration
│   │   ├── grafana.conf.template       # SSL-enabled server config template
│   │   └── grafana-init.conf           # Initial HTTP-only config (before SSL)
│   ├── loki-config.yaml                # Loki backend configuration
│   ├── tempo-config.yaml               # Tempo tracing backend configuration
│   ├── mimir-config.yaml               # Mimir metrics backend configuration
│   ├── otel-collector-config.yaml      # OTel Collector pipeline configuration
│   └── cloudwatch-agent-config.json    # CloudWatch agent configuration (EC2 only)
├── scripts/
│   ├── init-grafana.sh                 # Grafana user/team initialization script
│   ├── init-certbot.sh                 # Let's Encrypt certificate initialization
│   ├── renew-certs.sh                  # Certificate renewal script
│   ├── Dockerfile.grafana-init         # Init container Dockerfile
│   ├── send-test-telemetry.sh          # Test all pipelines (traces, logs, metrics)
│   ├── send-test-traces.sh             # Test traces pipeline
│   ├── send-test-logs.sh               # Test logs pipeline
│   └── send-test-metrics.sh            # Test metrics pipeline
├── docker-compose.yml                  # Local stack orchestration
├── main.tf                             # Terraform AWS infrastructure
├── user_data.tpl                       # EC2 initialization script
└── CLAUDE.md                           # This documentation (legacy location)
```

### Local Stack Architecture

Docker Compose orchestrates seven core services (plus two optional SSL services):

1. **Init Services** - Handle volume permissions for Tempo and Loki (run as user 10001)
2. **Loki** (port 3100) - Receives logs via Loki Push API from OTel Collector
3. **Tempo** (port 3200) - Receives traces via OTLP HTTP from OTel Collector
4. **Mimir** (port 9009) - Receives metrics via Prometheus Remote Write from OTel Collector
5. **Grafana** (port 3000) - Visualization layer with pre-configured datasources
6. **OTel Collector** (ports 4317/4318) - Central data collection point for OTLP data
7. **Grafana Init** - Creates default team and users from AWS Secrets Manager (runs once)

**SSL Services (profile: ssl):**
8. **NGINX** (ports 80/443) - SSL termination reverse proxy for Grafana
9. **Certbot** - Let's Encrypt certificate management with auto-renewal

### AWS Deployment Architecture

- **EC2 Instance** - Runs the Docker Compose stack in AWS
- **Security Groups** - Controls network access (HTTPS public, OTLP within VPC)
- **NGINX + Let's Encrypt** - SSL termination for Grafana (HTTPS)
- **User Data Script** - Automatically clones repository, starts services, and obtains SSL certificate
- **Secrets Manager** - Stores sensitive configuration (SSH keys, ports, instance details)

### EC2 Instance Specifications

| Component | Value | Reasoning |
|-----------|-------|-----------|
| **Instance Type** | t3a.xlarge | 4 vCPU, 16GB RAM - required for LGTM backends (Loki, Tempo, Mimir are memory-hungry). Check your chosen AZ actually offers the family; not every AZ carries every one. |
| **Disk Size** | 100GB gp3 | LGTM stack stores logs, traces, and metrics. 8GB caused disk full errors. 100GB provides ~1 month retention buffer. |
| **AMI** | Amazon Linux 2023 | Latest AL2023, auto-selected via Terraform data source |

**Cost estimate** (AWS list price, us-east-1): ~$117/mo (t3a.xlarge $109 + 100GB gp3 $8)

**Instance type is stored in Secrets Manager** (`/example/dev/lgtm-stack` → `instance_type`), allowing changes without modifying Terraform.

**Sizing guidelines:**

| Use Case | Instance | Disk | Monthly Cost |
|----------|----------|------|--------------|
| Dev/light | t3a.large (8GB) | 50GB | ~$55 |
| Standard | t3a.xlarge (16GB) | 100GB | ~$117 |
| Heavy/prod | t3a.2xlarge (32GB) | 200GB | ~$250 |

---

## Access Information

### AWS Deployment (Production)

- **Grafana UI**: https://grafana.example.com (SSL via Let's Encrypt)
- **OTLP Endpoints** (VPC-internal only, use internal DNS):
  - HTTP: `http://otel-collector.internal.example.com:4318`
  - gRPC: `http://otel-collector.internal.example.com:4317`

**DNS Configuration:**
- **Public:** `grafana.example.com` → EC2 public IP
- **Private:** `otel-collector.internal.example.com` → EC2 private IP (Route53 private hosted zone)

### Local Development

- **Grafana UI**: http://localhost:3000 (credentials from AWS Secrets Manager)
- **OTLP Endpoints**:
  - HTTP: `http://localhost:4318`
  - gRPC: `grpc://localhost:4317` (insecure)
- **Direct Service APIs** (usually accessed via Grafana):
  - Loki: http://localhost:3100
  - Tempo: http://localhost:3200
  - Mimir: http://localhost:9009

### Local Development with SSL (Optional)

To test SSL locally (uses Docker Compose profiles):

```bash
# Start with SSL profile (requires valid domain pointing to localhost)
docker compose --profile ssl up -d

# For local testing, you may need to use self-signed certificates
# or a tool like mkcert for local certificate generation
```

---

## Application Integration

### Using @your-org/instrumentation

```typescript
import {initOtelInstrumentation} from '@your-org/instrumentation';

initOtelInstrumentation({
    componentName: 'your-service-name'
});
```

### Manual OTLP Configuration

```bash
export OTEL_SERVICE_NAME="your-service-name"
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL="http/protobuf"

# Local development
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"

# AWS (within VPC) - use internal DNS
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector.internal.example.com:4318"
```

### Testing the Stack

```bash
# Test all pipelines locally
./scripts/send-test-telemetry.sh

# Test via SSH to EC2
./scripts/send-test-telemetry.sh --ssh

# Test from within VPC (uses internal DNS)
./scripts/send-test-telemetry.sh --prod

# Quick health check from EC2
wget -qO- http://otel-collector.internal.example.com:13133
```

---

## Data Persistence

Docker volumes for data persistence:

- `loki-data` - Loki log storage
- `tempo-data` - Tempo trace storage (requires special permissions via init service)
- `mimir-data` - Mimir metrics storage
- `grafana-data` - Grafana configuration and dashboards

---

## Grafana Users and Teams

### Overview

Grafana is automatically configured with a "Dev" team and default users on startup. The `grafana-init` service runs after Grafana is healthy and creates users/teams via the Grafana HTTP API.

### Credentials (AWS Secrets Manager)

All passwords are stored in AWS Secrets Manager at `/example/dev/lgtm-stack`:

| Secret Key | Purpose |
|------------|---------|
| `default_grafana_admin_password` | Grafana built-in admin account |
| `default_admin_password` | Team members with Admin role |
| `default_member_password` | Team members with Editor role |

### Default Users

Configured in `config/grafana/users-config.json`:

| Login | Role | Team |
|-------|------|------|
| admin (built-in) | GrafanaAdmin | Dev |
| admin@example.com | Admin | Dev |
| admin2@example.com | Admin | Dev |
| editor1@example.com | Editor | Dev |
| editor2@example.com | Editor | Dev |
| editor3@example.com | Editor | Dev |

### Configuration Files

- `config/grafana/users-config.json` - User and team definitions
- `scripts/init-grafana.sh` - Initialization script (idempotent)
- `scripts/Dockerfile.grafana-init` - Container with AWS CLI, jq, curl

### Behavior

- **Idempotent**: Safe to run multiple times - existing users are not modified
- **Password updates**: To change a user's password, delete them from Grafana UI first
- **Team membership**: All users are automatically added to the "Dev" team
- **Requires AWS credentials**: Mount `~/.aws` or set AWS environment variables

### Adding/Removing Users

Edit `config/grafana/users-config.json` and restart the stack:

```bash
docker compose down
docker compose up -d
```

The init container will create any new users. Removed users must be manually deleted from Grafana UI.

### Troubleshooting

```bash
# View init container logs
docker compose logs grafana-init

# Re-run initialization manually
docker compose up grafana-init

# Check if secrets are accessible
aws secretsmanager get-secret-value --secret-id /example/dev/lgtm-stack
```

---

## SSL/TLS Configuration

### Overview

SSL is implemented using NGINX as a reverse proxy with Let's Encrypt certificates managed by Certbot. This setup is enabled automatically on AWS deployments and optionally for local development.

### Architecture

```
Internet --> NGINX (443/SSL) --> Grafana (3000/HTTP)
                |
                +--> Let's Encrypt ACME (80)
```

### Certificate Management

- **Initial Certificate**: Obtained automatically during EC2 first boot via user_data script
- **Auto-Renewal**: Certbot container checks every 12 hours and renews if within 30 days of expiry
- **Certificate Location**: `/etc/letsencrypt/live/grafana.example.com/`

### Configuration Files

| File | Purpose |
|------|---------|
| `config/nginx/nginx.conf` | Main NGINX configuration |
| `config/nginx/grafana.conf.template` | SSL-enabled server config (post-certificate) |
| `config/nginx/grafana-init.conf` | HTTP-only config (during certificate acquisition) |
| `scripts/init-certbot.sh` | Certificate initialization script |
| `scripts/renew-certs.sh` | Certificate renewal script |

### Troubleshooting SSL

```bash
# Check NGINX status
docker compose logs nginx

# Check certificate status
docker exec certbot certbot certificates

# Test NGINX configuration
docker exec nginx nginx -t

# Force certificate renewal (for testing)
docker exec certbot certbot renew --force-renewal

# Check SSL certificate details
openssl s_client -connect grafana.example.com:443 -servername grafana.example.com

# View EC2 SSL setup logs
ssh ec2-user@<instance-ip> "cat /tmp/git-clone-setup.log | grep -A20 'SSL certificate'"
```

### Manual Certificate Renewal

If auto-renewal fails:

```bash
# SSH to EC2 instance
ssh ec2-user@<instance-ip>

# Run certbot renewal manually
cd ~/lgtm_stack
docker-compose exec certbot certbot renew --webroot -w /var/www/certbot

# Reload NGINX to pick up new certificate
docker-compose exec nginx nginx -s reload
```

---

## CloudWatch Monitoring

### Overview

The EC2 instance runs the Amazon CloudWatch agent to collect host metrics, and ship logs to CloudWatch. This provides infrastructure-level observability complementing the LGTM application telemetry.

### What's Monitored

| Category | Metrics/Logs | CloudWatch Location |
|----------|--------------|---------------------|
| **CPU** | usage_idle, usage_iowait, usage_user, usage_system | `LGTM/EC2` namespace |
| **Memory** | used_percent, available, total, used | `LGTM/EC2` namespace |
| **Disk** | used_percent, inodes_free/used/total | `LGTM/EC2` namespace |
| **Disk I/O** | io_time, write/read_bytes, writes/reads | `LGTM/EC2` namespace |
| **Network** | bytes_sent/recv, packets_sent/recv | `LGTM/EC2` namespace |
| **Swap** | swap_used_percent | `LGTM/EC2` namespace |
| **System Logs** | /var/log/messages | `/lgtm/ec2/system` log group |
| **Docker Daemon** | Docker daemon logs | `/lgtm/ec2/docker-daemon` log group |
| **Setup Logs** | user_data script output | `/lgtm/ec2/setup` log group |

### Configuration

- **Config file**: `config/cloudwatch-agent-config.json`
- **Collection interval**: 60 seconds
- **Log retention**: 14 days

### IAM Requirements

The EC2 instance has an IAM role (`lgtm-ec2-instance-role`) with:
- `CloudWatchAgentServerPolicy` - Push metrics and logs to CloudWatch
- `AmazonSSMManagedInstanceCore` - SSM access (optional)

### Troubleshooting CloudWatch Agent

```bash
# SSH to EC2 instance first
ssh ec2-user@<instance-ip>

# Check agent status
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -m ec2 -a status

# View agent logs
sudo tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log

# Restart agent with config
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Check if agent is running
sudo systemctl status amazon-cloudwatch-agent
```

### Viewing Metrics in AWS Console

1. Go to **CloudWatch** > **Metrics** > **All metrics**
2. Select **LGTM/EC2** namespace
3. Filter by InstanceId to see host metrics

### Viewing Logs in AWS Console

1. Go to **CloudWatch** > **Log groups**
2. Look for log groups starting with `/lgtm/`

---

## Troubleshooting

### Expected Startup Behavior

- Loki, Tempo, and Mimir show "Ingester not ready: waiting for 15s after being ready" during initial startup
- This is normal stabilization behavior - services will be fully ready after the wait period
- Grafana datasource configurations use explicit HTTP protocol to prevent gRPC auto-detection issues

### Common Issues

**gRPC Connection Errors**
- **Solution**: Configure `httpMethod: GET` in Tempo datasource

**Service Not Ready**
- **Solution**: Wait 1-2 minutes for full stack stabilization

**Connection Timeouts**
- **Solution**: Verify all containers are healthy with `docker compose ps`

**HTTP/2 Protocol Errors (ERR_HTTP2_PROTOCOL_ERROR)**
- **Symptom**: Browser shows "Grafana has failed to load its application files" with ERR_HTTP2_PROTOCOL_ERROR in console
- **Cause**: NGINX proxy buffers too small for Grafana's JavaScript bundles, or disk full causing temp file failures
- **Solution**: The NGINX config (`config/nginx/grafana.conf.template`) includes proxy buffer settings:
  ```nginx
  proxy_buffer_size 128k;
  proxy_buffers 4 256k;
  proxy_busy_buffers_size 256k;
  ```
- **Also check**: Disk space (`df -h`) - if disk is full, NGINX can't write temp files

**Disk Full on EC2**
- **Symptom**: Various failures, Docker errors, NGINX unresponsive
- **Diagnosis**: `df -h` shows 100% usage on `/dev/xvda1`
- **Quick fix**: `docker system prune -a -f` to remove unused images/containers
- **Permanent fix**: Increase disk size (see EC2 Instance Specifications above)
- **Note**: The original 8GB default was insufficient for LGTM stack; now configured for 100GB

**NGINX Deprecation Warning**
- **Warning**: `the "listen ... http2" directive is deprecated`
- **Solution**: Use separate directives (already fixed in template):
  ```nginx
  listen 443 ssl;
  http2 on;
  ```

### Debug Commands

```bash
docker compose ps                      # Check container status
docker compose logs -f <service>       # Stream service logs
docker exec -it <container> sh         # Shell into container
```

### EC2 Troubleshooting via AWS Systems Manager (SSM)

When SSH access is unavailable or inconvenient, use AWS Systems Manager to connect to the EC2 instance. SSM is pre-configured via the IAM instance role.

**Prerequisites:**
- AWS CLI configured with appropriate credentials
- Instance must be running and SSM agent online
- Session Manager plugin installed (for interactive sessions)

**Installing Session Manager Plugin (one-time setup):**

```bash
# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb

# Verify installation
session-manager-plugin --version
```

**1. Get the EC2 Instance ID from Terraform state:**

```bash
# Using OpenTofu
tofu show -json | jq -r '.values.root_module.resources[] | select(.type == "aws_instance") | .values.id'

# Using Terraform
terraform show -json | jq -r '.values.root_module.resources[] | select(.type == "aws_instance") | .values.id'
```

**2. Verify SSM agent is online:**

```bash
INSTANCE_ID="i-0123456789abcdef0"  # Replace with actual ID
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[*].{InstanceId:InstanceId,PingStatus:PingStatus}' \
  --output table
```

**3. Connect interactively (recommended):**

```bash
# Start an interactive shell session
aws ssm start-session --target "$INSTANCE_ID"

# Once connected, switch to ec2-user for proper environment
sudo su - ec2-user

# Navigate to the stack directory
cd ~/lgtm_stack

# Now you can run docker-compose commands directly
docker-compose --profile ssl ps
docker-compose --profile ssl logs -f nginx
```

**4. Run commands via SSM (non-interactive alternative):**

```bash
# Check container status
aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl ps"]' \
  --output json --query 'Command.CommandId'

# Get command output (replace COMMAND_ID with the returned ID)
aws ssm get-command-invocation \
  --command-id "COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
  --output json
```

**5. Common SSM troubleshooting commands:**

```bash
# View setup logs
commands=["cat /tmp/git-clone-setup.log | tail -100"]

# Check all container status with SSL profile
commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl ps"]

# View specific service logs
commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl logs nginx --tail 50"]

# Check SSL certificate status
commands=["docker exec certbot certbot certificates"]

# Manually obtain SSL certificate
commands=["docker exec certbot certbot certonly --webroot -w /var/www/certbot -d grafana.example.com --email devops@example.com --agree-tos --no-eff-email --non-interactive"]

# Activate SSL config and reload NGINX
commands=["cd /home/ec2-user/lgtm_stack && bash scripts/render-nginx-ssl.sh ssl grafana.example.com"]

# Restart entire stack
commands=["cd /home/ec2-user/lgtm_stack && docker-compose --profile ssl down && docker-compose --profile ssl up -d"]
```

**Notes:**
- SSM commands run as root, not ec2-user
- Git operations via SSM will fail (SSH keys are configured for ec2-user only)
- Set `HOME` environment variable if needed: `export HOME=/home/ec2-user`
- Commands that modify files in the container are ephemeral unless volumes are used

---

## Agents

### Available Agents

#### Global Agents (inherited from your organization)
- **git-research-agent** - Git workflow analysis, commit history, branch strategy, repository health
  - Invoke for: Analyzing git history, understanding feature implementation timeline, assessing commit patterns

#### Repository Agents (specific to lgtm-stack-experiment)

**Data Pipeline & Backends:**
- **otel-collector-architecture-agent** - OTel Collector pipeline configuration, receivers, processors, exporters
  - Location: `.claude/agents/otel-collector-architecture-agent.md`
  - Invoke for: Pipeline optimization, configuration analysis, reliability patterns, backend integration research
- **lgtm-backends-config-agent** - Loki, Tempo, and Mimir backend configuration optimization and troubleshooting
  - Location: `.claude/agents/lgtm-backends-config-agent.md`
  - Invoke for: Storage configuration, retention policies, ingestion limits, query performance tuning, production readiness
- **lgtm-config-compatibility-agent** - Configuration compatibility, deprecation tracking, and version migration research
  - Location: `.claude/agents/lgtm-config-compatibility-agent.md`
  - Invoke for: Deprecated option detection, breaking change identification, version upgrade planning, configuration validation against latest docs

**Visualization & Correlation:**
- **grafana-visualization-agent** - Dashboard design, datasource configuration, alerting patterns
  - Location: `.claude/agents/grafana-visualization-agent.md`
  - Invoke for: Dashboard design, datasource correlation setup, visualization best practices, Grafana alerting
- **observability-correlation-agent** - Cross-signal correlation (trace-to-logs, exemplars, service maps)
  - Location: `.claude/agents/observability-correlation-agent.md`
  - Invoke for: Trace-to-log linking, metrics exemplars, service graph setup, semantic conventions

**Infrastructure & Operations:**
- **terraform-aws-infrastructure-agent** - AWS infrastructure patterns, security, cost optimization
  - Location: `.claude/agents/terraform-aws-infrastructure-agent.md`
  - Invoke for: EC2 configuration, security groups, Secrets Manager, VPC patterns, Terraform best practices
- **docker-compose-orchestration-agent** - Container orchestration, health checks, resource management
  - Location: `.claude/agents/docker-compose-orchestration-agent.md`
  - Invoke for: Service dependencies, startup ordering, health checks, volume permissions, networking
- **alerting-sre-patterns-agent** - Alert design, SLO/SLI patterns, error budgets
  - Location: `.claude/agents/alerting-sre-patterns-agent.md`
  - Invoke for: Alert rule design (LogQL/PromQL), SLO definition, notification routing, recording rules

**Agent definitions:** `.claude/agents/{agent-name}.md`
**Research outputs:** `.claude/agents/{agent-name}/docs/`
**To add an agent:** Use `/add-agent` command

---

## Sessions

Complex features use session files for tracking:

**Location:** `.claude/sessions/YYYY-MM-DD-[TICKET-XXX-]feature-name.md`

**Create session when:**
- Modifying observability pipeline configuration
- Adding new backends or exporters
- AWS infrastructure changes
- Performance tuning investigations

**Session guide:** keep one session file per complex feature under `.claude/sessions/` and archive it when the work lands.

---

## Reference

| Need | Location |
|------|----------|
| **Global standards** | Your organization-wide coding standards |
| **Platform architecture** | Your platform architecture overview |
| **Instrumentation package** | Your OTel instrumentation package |
| **OTel Collector docs** | https://opentelemetry.io/docs/collector/ |
| **Grafana LGTM docs** | https://grafana.com/docs/ |

---

## Notes

- **Startup Time**: Stack requires ~15 seconds for full readiness
- **Tempo Permissions**: Init service handles volume permissions for Tempo (user 10001)
- **gRPC vs HTTP**: Use explicit HTTP protocol in datasource configs to prevent gRPC auto-detection issues
- **AWS Deployment**: Uses Terraform with Secrets Manager for sensitive configuration
- **Docker Compose Command**: Local uses `docker compose` (space, CLI plugin); EC2 uses `docker-compose` (hyphen, standalone binary)
