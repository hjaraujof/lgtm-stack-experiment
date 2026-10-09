# LGTM Local Stack

**Repository Type:** Infrastructure Tooling
**Purpose:** LGTM (Loki, Grafana, Tempo, Mimir) observability stack for local development and AWS deployment

Every `*.example.com` name, the Secrets Manager path `/example/dev/lgtm-stack` and every `@your-org/` package are placeholders. A command that contains one reaches no real system until you substitute your own values.

Three deployment planes share `config/` and `scripts/`: Docker Compose (local), one EC2 host (`main.tf`, `user_data.tpl`), and a Helm chart (`k8s/`, on kind locally or on the EKS cluster in `terraform/eks/`). The chart carries copies of `config/` and `scripts/*.sh`. After you edit either, run `make -C k8s sync-config`, or `helm-check.yml` fails on the drift.

---

## Local or EC2: ask first

When troubleshooting, ask this before anything else:

> "Are we troubleshooting the **local development** stack or the **deployed EC2 instance**?"

| Aspect | Local | EC2 |
|--------|-------|-----|
| **Access** | Direct `docker compose` commands | SSM Session Manager. SSH (port 22) is closed in `main.tf` (see Troubleshooting section) |
| **Docker command** | `docker compose` (space) | `docker-compose` (hyphen) |
| **Grafana URL** | `http://localhost:3000` | `https://grafana.example.com` |
| **Logs** | `docker compose logs <service>` | SSM + `docker-compose logs` |
| **NGINX/SSL** | Optional (profile) | Always active |
| **Network issues** | Usually container networking | Security groups, DNS, VPC |

---

## Quick Start

- `docker compose up -d` starts the stack locally. `docker compose down -v` wipes it. The data lives in the named volumes declared under `volumes:` in `docker-compose.yml`; `./data/` holds only `.gitkeep`.
- The IaC tool is OpenTofu. Run `tofu`, not `terraform`: `.terraform.lock.hcl` pins providers from `registry.opentofu.org`, so a `terraform init` re-resolves them from a different registry.

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

---

## Reading Telemetry: Sampling, and Which Plane to Trust

Span metrics and traces are sampled at different points, so the two planes disagree by design.

- **Head sampling** happens in the application's OTel SDK (for example `ParentBased(root=TraceIdRatioBased(r))`), before the collector sees anything. It affects every plane, and no collector policy can recover a dropped trace. The `keep-errors` tail policy sees only what the SDK exported.
- **Tail sampling** affects Tempo only. In `config/otel-collector-config.yaml`, `traces/in` exports to the `spanmetrics` and `servicegraph` connectors and to `forward`, and only `traces/store` (fed by `forward`) runs `tail_sampling`. The shipped example keeps `service.name` matching `.*/(dev|prod)/.*`, every error, every trace over 200 ms, and 10% of the rest.

So the keep rate is per plane, not per environment. Span metrics carry the head rate `r`; Tempo carries `r` times the tail policy. Check both for the service and environment before you scale a count. Scaling an unsampled plane by a keep rate overstates it by 1/r.

- Rates, ratios and percentiles survive sampling unbiased. Absolute counts are low by the keep rate: divide by it, or do not quote them.
- Events clustered inside one trace cannot be recovered by scaling, because sampling keeps or drops whole traces. A scaled count can exceed the true total.
- For volume or error counts at a backend, trust the backend's own server-side metrics (CloudWatch, for an AWS service). Use Tempo for the code path, span-metric ratios for RED, and `traces_span_metrics_calls_total` for pipeline liveness only. Check a CloudWatch metric's dimensions with `aws cloudwatch list-metrics` first: some carry only a table-level dimension and sum across operations.
- A span-metric series outlives the traffic that created it. `metrics_expiration: 48h` evicts an idle resource (keyed on `service.name`), never a stale `span.name` inside a live service. Ask "does this still emit X" with `rate(...[10m]) > 0`, never with series existence. Only a collector restart clears the cache, so confirm that no restart fell between two snapshots before you compare them (`docker inspect -f '{{.State.StartedAt}}' otel-collector`).
- For a total over a window, use `increase(m[6h])`, not `avg_over_time(rate(m[5m])[6h:1m]) * 21600`. On bursty series the subquery compounds the `rate[5m]` extrapolation and overstates the total. To confirm a figure, sum aligned 1h `increase` chunks.

---

## Architecture

### Local stack: what the files do not say

- Loki, Tempo, Mimir and the collector have no container healthcheck, because their images are distroless. `docker compose ps` never shows them `healthy`. Readiness is at `localhost:3100/ready`, `localhost:3200/ready`, `localhost:9009/ready` and the collector's `localhost:13133/`.
- Logs reach Loki through its native OTLP endpoint (`otlphttp/loki` to `http://loki:3100/otlp`), not the Loki push API.
- Mimir rules deploy from git: `config/mimir/rules/` is a read-only bind mount that the ruler polls. The Alertmanager config goes through `mimir-am-init`, which re-applies `config/mimir/alertmanager/demo-am.yaml` every 60s. An API write to the tenant config is reverted within one interval, so edit the file.
- Mimir (`common.storage`) and Tempo (`storage.trace`) are configured `backend: s3`, with a placeholder bucket and instance-role credentials. Nothing in `config/` switches them to the filesystem for a local run.
- The init containers (`init`, `init-loki`, `init-otelcol-queue`) chown the Tempo, Loki and collector-queue volumes to UID 10001. They use `busybox` on purpose: the distroless service images have no `chown`.

### AWS Deployment Architecture

- **EC2 Instance** - Runs the Docker Compose stack in AWS
- **Security Groups** - Controls network access (HTTPS public, OTLP within VPC)
- **NGINX + Let's Encrypt** - SSL termination for Grafana (HTTPS)
- **User Data Script** - Fetches the stack from the S3 bootstrap bucket as a checksum-verified `git archive` (`bootstrap.tf`, published by `.github/workflows/publish-bootstrap.yml`), writes `.env`, runs `docker-compose --profile ssl up -d` and obtains the certificate. No git credential and no `.git` directory exist on the box.
- **Secrets Manager** - `user_data.tpl` reads the three Grafana passwords from it at boot, through the instance role. Terraform reads only the secret's metadata, never its value. Instance type and ports are Terraform variables (`variables.tf`).

### EC2 Instance Specifications

Do not take the running box's size from this file. `main.tf` sets `instance_type = var.instance_type` (default `t3a.xlarge` in `variables.tf`; 16 GB RAM is the practical floor) and a hard-coded 150 GB gp3 root volume. A resize done outside Terraform leaves no trace in the repo, and the next `tofu apply` reverts it. Before any capacity or cost conclusion, read the running instance (`aws ec2 describe-instances`, `aws ec2 describe-volumes`) and confirm with `tofu plan`.

**AMI:** Amazon Linux 2023, resolved with `most_recent = true` and pinned by `lifecycle { ignore_changes = [ami] }`. If that line goes, the next apply replaces the instance. Replacement destroys the root volume and everything on it, including Loki's filesystem store and Grafana's state. Only the S3-backed Mimir and Tempo blocks survive.

**Sizing reference points** for a resize decision, not a description of the current box:

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

- **Grafana UI**: http://localhost:3000. The admin login is `admin`/`admin` unless `.env` sets `GRAFANA_ADMIN_PASSWORD`; `scripts/setup-local-env.sh` writes `.env` from Secrets Manager.
- **OTLP Endpoints**:
  - HTTP: `http://localhost:4318`
  - gRPC: `grpc://localhost:4317` (insecure)
- **Direct Service APIs** (usually accessed via Grafana). Loki (`auth_enabled: true`) and Mimir are multi-tenant, so send `X-Scope-OrgID: demo`, the tenant the collector writes and the datasources read. Tempo runs with auth disabled.
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

# From outside the VPC. --ssh SSHes to ec2-user, but port 22 is closed unless you
# re-add the break-glass rule in main.tf, and it reads ec2_public_ip from the secret.
# Otherwise run the script on the box through SSM.
./scripts/send-test-telemetry.sh --ssh

# Test from within VPC (uses internal DNS)
./scripts/send-test-telemetry.sh --prod

# Quick health check from EC2
wget -qO- http://otel-collector.internal.example.com:13133
```

---

## Grafana Users and Teams

`grafana-init` runs once Grafana is healthy. It creates the "Dev" team and the users in `config/grafana/users-config.json` (placeholders) through the Grafana HTTP API. Passwords come from `.env`, or locally from Secrets Manager through the mounted `~/.aws`. README "Grafana users & teams" lists the secret keys and the re-run commands.

- It skips a user that already exists. To change a password, delete the user in the Grafana UI, then run `docker compose up grafana-init`.
- Removing a user from the JSON does not remove it from Grafana. Delete it in the UI.

---

## SSL/TLS Configuration

NGINX and Certbot run under the `ssl` Compose profile, which EC2 always uses. The Certbot container runs `scripts/renew-certs.sh` every 12h. That renews inside 30 days of expiry and reloads nginx through the mounted Docker socket. The certificate sits in the `certbot-etc` volume under `/etc/letsencrypt/live/<domain>/`.

`scripts/render-nginx-ssl.sh init` (HTTP-only, for the ACME challenge) and `scripts/render-nginx-ssl.sh ssl <domain>` render `config/nginx/grafana.conf.template` on the host into `config/nginx/conf.d/`, test it, then reload. Do not render inside the container, and do not bind-mount a single file onto `conf.d/grafana.conf`: that setup once wrote through the mount and overwrote a tracked file at runtime (see the nginx comment in `docker-compose.yml`).

```bash
docker compose logs nginx
docker exec certbot certbot certificates
docker exec nginx nginx -t
docker exec certbot certbot renew --force-renewal   # testing only
openssl s_client -connect grafana.example.com:443 -servername grafana.example.com
```

On EC2, run these through SSM from `~/lgtm_stack` with `docker-compose`. First-boot certificate output is in `/tmp/git-clone-setup.log`. If auto-renewal fails, run `docker-compose exec certbot certbot renew --webroot -w /var/www/certbot`, then `docker-compose exec nginx nginx -s reload`.

---

## CloudWatch Monitoring

The EC2 host runs the CloudWatch agent with `config/cloudwatch-agent-config.json`: namespace `LGTM/EC2`, log groups `/lgtm/ec2/*`, 60s collection, 14-day retention. It pushes through `CloudWatchAgentServerPolicy` on `lgtm-ec2-instance-role`. Agent troubleshooting and console steps: `.claude/docs/cloudwatch-agent.md`.

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
- **Solution**: `docker compose ps` shows state, not readiness. Only Grafana and NGINX have a healthcheck. Probe `curl -s localhost:3100/ready`, `localhost:3200/ready`, `localhost:9009/ready` and `localhost:13133/`

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
- **Diagnosis**: `df -h /` shows 100% usage on the root filesystem
- **Quick fix**: `docker system prune -a -f` to remove unused images/containers
- **Permanent fix**: Increase disk size (see EC2 Instance Specifications above)
- **Note**: The original 8GB default was insufficient. `main.tf` now sets 150 GB. Read the live size with `aws ec2 describe-volumes`, not from this file

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

### EC2 access (SSM)

SSH (port 22) is closed in `main.tf`, so SSM Session Manager is the routine way in. The step-by-step runbook (instance id, agent check, interactive session, `send-command` recipes) is the `ec2-ssm-access` skill in `.claude/skills/ec2-ssm-access/SKILL.md`.

- SSM `send-command` runs as root, and an interactive `start-session` shell runs as `ssm-user`. Neither is ec2-user. Run `sudo su - ec2-user` first, or `export HOME=/home/ec2-user` in a one-shot command.
- The stack lives at `~/lgtm_stack` (`/home/ec2-user/lgtm_stack`). It is a `git archive` extract with no `.git` directory, so git fails there for every user. The instance fetches the archive only at boot.
- The boot and setup log is `/tmp/git-clone-setup.log`. The name predates the S3 boot.

---

## Agents

The repository's research agents live in `.claude/agents/<name>.md`, with their reference docs under `.claude/agents/<name>/docs/`. Their frontmatter has `description:` but no `name:`, and Claude Code rejects an agent file without `name`, so none of them registers as a subagent type. Read the file directly, or add a `name:` line first. `/add-agent` scaffolds a new agent.

---

## Reference

| Need | Location |
|------|----------|
| **OTel Collector docs** | https://opentelemetry.io/docs/collector/ |
| **Grafana LGTM docs** | https://grafana.com/docs/ |
