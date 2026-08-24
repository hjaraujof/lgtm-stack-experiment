# lgtm-stack-experiment

A self-contained, reference **LGTM observability stack** — **L**oki (logs), **G**rafana
(visualization), **T**empo (traces), and **M**imir (metrics) — fronted by an
OpenTelemetry Collector. It runs locally with Docker Compose for development, and ships
with an optional OpenTofu module to deploy the same stack to a single AWS EC2 host with
NGINX + Let's Encrypt TLS. A third deployment plane — a hand-written Helm chart and a kind
cluster — lives in [`k8s/`](k8s/README.md).

This repository is an **org-agnostic experiment**: every identifier (domains, AWS
account, DNS names, Secrets Manager paths, users, service names) is a generic
placeholder. Swap the placeholders for your own values before deploying anywhere real.

```text
Application ──OTLP──▶ OTel Collector ──▶ { Loki, Tempo, Mimir } ──▶ Grafana
```

---

## Contents

- [What's in the box](#whats-in-the-box)
- [Quick start (local)](#quick-start-local)
- [Accessing services](#accessing-services)
- [Sending telemetry](#sending-telemetry)
- [Testing the stack](#testing-the-stack)
- [Service naming assumption](#service-naming-assumption)
- [Dashboards, recording rules, and alerts](#dashboards-recording-rules-and-alerts)
- [Validation and tests](#validation-and-tests)
- [OTel Collector: tail sampling](#otel-collector-tail-sampling)
- [Grafana users & teams](#grafana-users--teams)
- [AWS deployment (OpenTofu)](#aws-deployment-opentofu)
- [Kubernetes deployment (Helm)](#kubernetes-deployment-helm)
- [SSL/TLS (NGINX + Let's Encrypt)](#ssltls-nginx--lets-encrypt)
- [Repository layout](#repository-layout)
- [Developer-assistance tooling](#developer-assistance-tooling)

---

## What's in the box

| Capability | Where |
|---|---|
| Local Docker Compose stack (Loki, Tempo, Mimir, Grafana, OTel Collector) | `docker-compose.yml`, `config/` |
| Optional single-host AWS deploy (EC2 + user-data bootstrap) | `main.tf`, `user_data.tpl` |
| Kubernetes deploy: a hand-written Helm chart, a kind cluster, and a separate EKS module | `k8s/`, `terraform/eks/` |
| S3-backed object storage for Mimir + Tempo blocks | `s3-backends.tf`, `config/mimir-config.yaml`, `config/tempo-config.yaml` |
| CloudWatch alarms + SNS notifications for the EC2 host | `alerting.tf` |
| NGINX reverse proxy with automatic Let's Encrypt TLS | `config/nginx/`, `scripts/init-certbot.sh`, `scripts/renew-certs.sh` |
| Grafana user/team provisioning from a secrets store | `config/grafana/users-config.json`, `scripts/init-grafana.sh` |
| Provisioned datasources (Loki, Tempo, Mimir) with trace↔log correlation | `config/grafana/provisioning/datasources/datasources.yaml` |
| Demo-service dashboards, a golden-path per-service RED template, and a stack self-health dashboard | `config/grafana/provisioning/dashboards/` |
| 31 alert rules and 16 recording rules: RED, SLO burn rate, latency and auth SLIs, pipeline and discard tripwires, alert-path integrity | `config/mimir/rules/demo/` |
| Alertmanager routing with a Watchdog heartbeat, plus a reconciler that makes `git pull` the deploy and reverts out-of-band writes | `config/mimir/alertmanager/`, `scripts/init-mimir-alertmanager.sh` |
| A runbook per alert, linked from each rule's `runbook_url` | `docs/runbooks/` |
| promtool rule unit tests + a reconciler integration test with a negative control | `tests/` |
| CI that validates every config this repo deploys, each validator paired with a positive control | `.github/workflows/` |
| OTel Collector RED span metrics + service-graph + tail sampling + internal-telemetry scrapes | `config/otel-collector-config.yaml` |
| Telemetry test scripts (traces / logs / metrics) | `scripts/send-test-*.sh` |

### Components & ports

| Component | Port | Purpose |
|-----------|------|---------|
| **Grafana** | 3000 | Visualization / dashboards |
| **Loki** | 3100 | Log aggregation |
| **Tempo** | 3200 | Distributed tracing backend |
| **Mimir** | 9009 | Prometheus-compatible metrics backend |
| **OTel Collector** | 4317 / 4318 / 13133 | OTLP gRPC / OTLP HTTP / health check |
| **NGINX** | 80 / 443 | TLS termination reverse proxy (AWS profile) |
| **Certbot** | — | Let's Encrypt certificate management (AWS profile) |

---

## Quick start (local)

**Prerequisites:** Docker Engine and Docker Compose v2 (`docker compose`, with a space).

```bash
# Start the whole stack in the background
docker compose up -d

# Watch it come up (allow ~15s for Loki/Tempo/Mimir to finish stabilizing)
docker compose ps
docker compose logs -f

# Tear down (data is preserved in named volumes)
docker compose down

# Tear down AND wipe all persisted data
docker compose down -v
```

> During startup, Loki/Tempo/Mimir may log `Ingester not ready: waiting for 15s after
> being ready`. This is normal — they are fully ready after the stabilization window.

---

## Accessing services

| Service | URL | Notes |
|---------|-----|-------|
| **Grafana** | http://localhost:3000 | Local default `admin` / `admin` (change it). |
| **Loki** | http://localhost:3100 | Usually queried via the Grafana datasource. |
| **Tempo** | http://localhost:3200 | Usually queried via the Grafana datasource. |
| **Mimir** | http://localhost:9009 | Usually queried via the Grafana datasource. |
| **OTel Collector (OTLP HTTP)** | http://localhost:4318 | Application telemetry ingress. |
| **OTel Collector (OTLP gRPC)** | grpc://localhost:4317 | Use an insecure connection locally. |
| **OTel Collector health** | http://localhost:13133/ | Liveness/readiness. |

The Grafana datasources (Loki, Tempo, Mimir) are provisioned automatically and wired for
trace-to-log correlation via a `traceID` derived field. Tempo is configured with
`httpMethod: GET` to avoid gRPC auto-detection issues.

---

## Sending telemetry

Point your application's OpenTelemetry SDK at the collector's OTLP endpoint:

```bash
export OTEL_SERVICE_NAME="your-service-name"
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL="http/protobuf"   # or grpc
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"  # collector HTTP

# To also ship logs and metrics over OTLP:
# export OTEL_LOGS_EXPORTER="otlp"
# export OTEL_METRICS_EXPORTER="otlp"

node your-app.js
```

If your organization publishes instrumentation/logging helper packages
(e.g. `@your-org/instrumentation`, `@your-org/logging`), a common gotcha is that the
logger only registers its OTLP transport when `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` **or**
`OTEL_EXPORTER_OTLP_ENDPOINT` is set — see [`docs/otlp-logs-rollout.md`](docs/otlp-logs-rollout.md)
for the full logs-not-appearing playbook.

---

## Testing the stack

Scripts in `scripts/` exercise each pipeline end-to-end and confirm data lands in the
backends.

| Script | Purpose |
|--------|---------|
| `scripts/send-test-traces.sh` | Send test traces to Tempo |
| `scripts/send-test-logs.sh` | Send test logs to Loki |
| `scripts/send-test-metrics.sh` | Send test metrics to Mimir |
| `scripts/send-test-telemetry.sh` | Run all three at once |

```bash
# Local stack (default endpoint http://localhost:4318)
./scripts/send-test-telemetry.sh

# Against a remote/AWS host over SSH
./scripts/send-test-telemetry.sh --ssh

# From inside the VPC (uses internal DNS)
./scripts/send-test-telemetry.sh --prod

# Custom endpoint
./scripts/send-test-telemetry.sh --endpoint http://custom-host:4318

# Individual scripts accept a count
./scripts/send-test-traces.sh 5
./scripts/send-test-logs.sh 10
./scripts/send-test-metrics.sh 3
```

Then confirm in **Grafana → Explore**:

| Signal | Datasource | Query |
|--------|------------|-------|
| Traces | Tempo | `{resource.service.name="test-trace-generator"}` |
| Logs | Loki | `{service_name="test-log-generator"}` |
| Metrics | Mimir | `http_requests_total{service_name="test-metric-generator"}` |

---

## Service naming assumption

Every alert that pages only for live traffic depends on one convention. **This stack assumes
`service.name` is the compound string `<tenant>/<env>/<component>`**, for example:

```text
tenant-a/prod/orders-api
tenant-b/qa/web-portal
```

That compound name is the **only env-bearing label on the span metrics**, because the apps here do
not set the `service.namespace` resource attribute — and `config/otel-collector-config.yaml`
deliberately deletes it if they do (see the `transform/normalize` comment for why). Alerts therefore
select the environment with a regex on the middle segment:

```promql
service_name=~"[^/]+/(prod|uat)/[^/]+"
```

**If your services do not use this convention, replace that regex everywhere it appears** — in
`stack-alerts.yaml`, `slo-burn.yaml`, and the `tail_sampling` policies in the collector config. The
alternative is to emit the standard OTel `deployment.environment` attribute and add it as a
spanmetrics dimension, which is cleaner but is not what these files ship with.

Pre-production environments are excluded from live paging on purpose. A pager that fires on qa noise
trains its reader to ignore it.

---

## Dashboards, recording rules, and alerts

### Dashboards

`config/grafana/provisioning/dashboards/`, provisioned automatically into three folders:

- **`demo-service/`** — per-service dashboards for a neutral `demo-service` across `dev`, `qa`,
  `uat`, `prod`, plus a global overview.
- **`services/service-red.json`** — the **golden-path template**. A `service_name` variable dashboard
  over the recorded RED series, so any newly instrumented service appears with zero bespoke dashboard
  work. Prefer extending this over hand-writing one dashboard per service.
- **`lgtm-health/lgtm-stack-health.json`** — the stack watching itself: pipeline liveness, Tempo and
  Mimir discards, compaction backlog. Every panel reads a series the stack already stores.

### Mimir rules (`config/mimir/rules/demo/`)

`git pull` **is** the deploy. `ruler_storage.backend=local` points at a read-only bind mount of that
directory, and the ruler re-scans it every `poll_interval`. No API call, no restart.

- **`red-recording.yaml`** — RED recording rules that pre-aggregate the collector's span metrics, so
  dashboards and alerts query cheap recorded series instead of raw histograms.
- **`slo-burn.yaml`** — multi-window multi-burn-rate availability SLO, an auth-failure SLI, a latency
  SLI, and a per-service telemetry-absence alert.
- **`stack-alerts.yaml`** — stack health and pipeline integrity: Tempo, Mimir, Loki and collector
  discard tripwires, plus the alert-path integrity rules.

Each rule's `runbook_url` points into [`docs/runbooks/`](docs/runbooks/README.md).

### Alertmanager (`config/mimir/alertmanager/demo-am.yaml`)

Also deployed by `git pull`, but through a different mechanism: the `mimir-am-init` container
reconciles the file into Mimir's config API every 60s. That is deliberate asymmetry, and the reason
is in the service's comment — object storage must stay the Alertmanager's backend so it keeps its own
silences and notification log.

A side effect worth knowing: **an out-of-band write to the tenant config is reverted within one
interval**, and `AlertmanagerConfigChanged` turns it into a signal.

### If you read only one thing here

The rule files are commented at length, because most of what they encode is not the threshold — it is
why a more obvious rule fails silently. Four lessons recur:

1. **Never read silence as health.** A quiet channel can mean the alert path is dead. Only an
   out-of-band detector distinguishes the two — here, a permanently-firing `Watchdog` rule routed to
   an unsubscribed topic, with a CloudWatch alarm counting its publishes.
2. **A trickle defeats an equality test.** A `== 0` detector cannot see a pipeline that is 99.8%
   dead. Pair every `== 0` with a floor.
3. **An empty selector is not a zero.** `count(...) == 0` never evaluates true on an absent series,
   so a detector written that way is silent forever. Use `absent()` — then keep the selector wide
   enough that a metric rename does not read as an outage.
4. **A per-reason allowlist fails silent.** Alerting on the discard reasons you have already seen is
   exactly how the next reason arrives unnoticed. Always carry a catch-all.

---

## Validation and tests

Nothing here is optional decoration: **this repo is the deployment path**, so a malformed config does
not degrade gracefully — it stops a component booting.

```bash
# Rule syntax, rule unit tests, and rule-file shape
docker run --rm -v "$PWD:/w:ro" -w /w --entrypoint promtool prom/prometheus:v3.1.0 \
  check rules config/mimir/rules/demo/*.yaml
docker run --rm -v "$PWD:/w:ro" -w /w --entrypoint promtool prom/prometheus:v3.1.0 \
  test rules tests/mimir-rules/*.test.yaml

# The Alertmanager reconciler's actual behaviour (stdlib Python, no install)
python3 tests/scripts/test-am-reconcile.py

# The Kubernetes plane. No cluster needed for any of these.
make -C k8s check-sync       # the chart copy has not drifted from config/ or scripts/
make -C k8s lint             # helm lint
make -C k8s validate         # every rendered object against the Kubernetes schema
make -C k8s verify-configs   # each backend's OWN validator, on the RENDERED config
tofu -chdir=terraform/eks validate
```

All of it runs in CI: `.github/workflows/mimir-rules-check.yml`,
`config-check.yml` and `helm-check.yml`. The second validates the collector, all three backends,
compose, nginx, every JSON and provisioning file, and every shell script.

`helm-check.yml` exists because the first two cannot see the Kubernetes plane. The chart does not
merely copy the configs: the Mimir and Tempo configs are re-emitted after a deep merge, and the
collector gateway config is the real file with the `hostmetrics` receiver removed. **A transform can
produce valid Kubernetes YAML and an invalid Loki config**, so that workflow extracts each rendered
ConfigMap and runs the same upstream validator against the exact bytes a pod will read.

**Every validator is paired with a positive control that asserts it REJECTS a deliberately broken
config.** That is not ceremony. Several of these validators pass vacuously when used slightly wrong —
`tempo -config.verify` without `=true` prints help and exits 0; `envsubst` on a machine that lacks it
yields an empty file that `nginx -t` happily accepts. A validation step that cannot detect failure is
worse than none, because it reports green forever.

---

## OTel Collector: tail sampling

The collector (`config/otel-collector-config.yaml`) is configured to keep telemetry costs
predictable while preserving signal:

- **RED span metrics** are computed on **100% of traffic** (the `spanmetrics` connector
  runs *before* sampling), so rate/error/duration numbers are unbiased regardless of how
  much trace volume is dropped.
- **Tail sampling** then decides which full traces to store. Policies are OR'd — a trace
  is kept if any policy matches. The shipped strategy keeps 100% of important environments
  plus all error/slow traces, and samples high-volume, low-value traffic at a reduced rate.

Tune the `tail_sampling` policies in the collector config to match your own environment
names and volume/cost trade-offs.

---

## Grafana users & teams

On startup, a one-shot `grafana-init` container provisions a team and a set of users via
the Grafana HTTP API. Definitions live in `config/grafana/users-config.json`; the logic is
in `scripts/init-grafana.sh` (built by `scripts/Dockerfile.grafana-init`).

- **Idempotent** — safe to re-run; existing users are left untouched.
- **Passwords come from a secrets store.** Locally you can supply them via environment;
  on AWS they are read from Secrets Manager (see below). The example users are generic
  placeholders (`admin@example.com`, `editor1@example.com`, …) — edit the JSON to define
  your own before deploying.

```bash
# Re-run provisioning against a running Grafana
docker compose up grafana-init

# Inspect provisioning logs
docker compose logs grafana-init
```

---

## AWS deployment (OpenTofu)

The HCL in this repo (`main.tf`, `s3-backends.tf`, `alerting.tf`, `user_data.tpl`)
provisions a single EC2 host that boots the same Docker Compose stack, backed by S3 for
Mimir/Tempo object storage and CloudWatch/SNS for host alerting. It is intentionally
minimal — a reference you adapt, not a turnkey production platform.

> **The tool is OpenTofu — run `tofu`, not `terraform`.** The Terraform CLI moved to the
> BUSL-1.1 source-available licence in 2023; OpenTofu is the MPL-2.0 fork under the Linux
> Foundation. `.terraform.lock.hcl` records providers from `registry.opentofu.org`, so a
> `terraform init` here would re-resolve them from a different registry.
>
> The `hashicorp/...` provider source addresses are **not** a licence problem. Only the CLI
> changed licence; the providers are still MPL-2.0, and OpenTofu serves them from its own
> registry. The prefix is a namespace, not a vendor.

> All values below are **placeholders**. Set your own domain, AWS account
> (`123456789012`), region, Secrets Manager path (`/example/dev/lgtm-stack`), and remote
> state bucket (`example-terraform-state`) before running anything.

```bash
tofu init      # remote state + providers
tofu plan      # review the change set
tofu apply     # provision the stack
tofu destroy   # tear it down
```

**How it works:**

1. OpenTofu reads only the secret's **metadata** (its ARN and name). It never reads
   the value, so no password reaches the state file or the rendered user-data.
2. `user_data.tpl` receives the secret NAME. On boot the instance fetches the values
   itself through its IAM role, and aborts loudly if the fetch comes back empty.
3. The instance pulls the stack as a **checksum-verified archive from S3**
   (`bootstrap.tf`, published by `.github/workflows/publish-bootstrap.yml`), not by
   git clone. No git credential exists on the box. It then writes its `.env` and brings
   the stack up. On AWS the SSL profile is enabled, so NGINX and Certbot obtain a
   certificate automatically.

**Secrets Manager keys** expected at `/example/dev/lgtm-stack`:

| Key | Purpose |
|-----|---------|
| `default_grafana_admin_password` | Grafana built-in admin account |
| `default_admin_password` | Team members with the Admin role |
| `default_member_password` | Team members with the Editor role |

> **Password gotcha:** Docker Compose treats `$` in `.env` files as variable
> interpolation. Generate passwords with alphanumeric characters only to avoid
> `The "…" variable is not set` warnings.

**Post-deploy verification:**

```bash
curl -s https://grafana.example.com/api/health | jq .   # Grafana
curl -s http://<instance-ip>:13133/ | jq .              # OTel Collector
```

### AWS endpoints (placeholders)

| Purpose | URL | Scope |
|---------|-----|-------|
| Grafana UI | `https://grafana.example.com` | Public (TLS) |
| OTLP HTTP | `http://otel-collector.internal.example.com:4318` | VPC only (internal DNS) |
| OTLP gRPC | `http://otel-collector.internal.example.com:4317` | VPC only (internal DNS) |

A private hosted zone (`internal.example.com`) is created and associated with the VPC so
any in-VPC workload can ship telemetry using a stable internal DNS name.

---

## Kubernetes deployment (Helm)

A third deployment plane, in [`k8s/`](k8s/README.md). It runs the same stack from a
**hand-written** Helm chart — every Deployment, StatefulSet, DaemonSet, ConfigMap, Job and
Ingress is written out rather than pulled from an upstream chart, because the object is the
thing being learned.

```bash
make -C k8s up      # kind cluster + controllers + install
make -C k8s test    # send OTLP, then read it back out of Mimir
make -C k8s destroy
```

It reuses the files in `config/` rather than restating them: the Services are named `loki`,
`tempo`, `mimir` and `grafana`, so `http://mimir:9009/api/v1/push` resolves in a cluster
exactly as it does under Compose. `k8s/README.md` maps every Compose service to its
Kubernetes object and explains each difference.

`terraform/eks/` is a **separate** OpenTofu root module, with its own state key, that builds
the AWS cluster. Neither plane can destroy the other.

Two differences worth knowing before reading the chart:

- **The collector splits in two.** The `hostmetrics` receiver moves to a DaemonSet, because
  a gateway pod sees one node and would report that node's CPU as the cluster's.
- **No credential exists on AWS.** Tempo and Mimir reach S3 through EKS Pod Identity or
  IRSA, and Grafana's password is mounted as a file by the Secrets Store CSI driver, so no
  Kubernetes Secret holds it.

---

## SSL/TLS (NGINX + Let's Encrypt)

Enabled automatically on AWS, and optional locally via the `ssl` Compose profile.

```text
Internet ──▶ NGINX (443/TLS) ──▶ Grafana (3000/HTTP)
                 └──▶ Let's Encrypt ACME (80)
```

```bash
# Bring the stack up with NGINX + Certbot locally
docker compose --profile ssl up -d
```

- Initial certificate is obtained on first boot via `scripts/init-certbot.sh`.
- `scripts/renew-certs.sh` / the Certbot container renews within 30 days of expiry.
- NGINX config lives in `config/nginx/` (`nginx.conf`, the HTTP-only bootstrap
  `grafana-init.conf`, and the TLS `grafana.conf.template`).
- `scripts/render-nginx-ssl.sh` renders the template **on the host** into the
  bind-mounted `config/nginx/conf.d/`, tests it, and only then reloads. Rendering
  inside the container would not survive a container recreate.

```bash
docker compose logs nginx                       # proxy logs
docker exec certbot certbot certificates        # cert status
docker exec nginx nginx -t                       # validate config
```

---

## Repository layout

```text
lgtm-stack-experiment/
├── docker-compose.yml            # Local (and EC2) stack orchestration
├── main.tf                       # AWS EC2 host + networking
├── s3-backends.tf                # S3 object storage for Mimir/Tempo
├── bootstrap.tf                  # S3 bucket the instance boots from (no git key on the box)
├── variables.tf                  # non-secret stack configuration
├── alerting.tf                   # CloudWatch alarms + SNS notifications
├── user_data.tpl                 # EC2 first-boot bootstrap
├── config/
│   ├── loki-config.yaml
│   ├── tempo-config.yaml
│   ├── mimir-config.yaml
│   ├── otel-collector-config.yaml
│   ├── cloudwatch-agent-config.json
│   ├── grafana/
│   │   ├── users-config.json                     # provisioned users/team
│   │   └── provisioning/
│   │       ├── datasources/datasources.yaml
│   │       └── dashboards/                        # demo-service dashboards
│   ├── mimir/
│   │   ├── rules/demo/                            # RED recording + stack alerts
│   │   └── alertmanager/demo-am.yaml
│   └── nginx/                                     # reverse proxy + TLS templates
├── scripts/
│   ├── init-grafana.sh / Dockerfile.grafana-init # user provisioning
│   ├── init-certbot.sh / renew-certs.sh          # TLS lifecycle
│   ├── setup-local-env.sh
│   └── send-test-*.sh                            # pipeline test scripts
├── k8s/                                          # THIRD PLANE: Kubernetes
│   ├── charts/lgtm-stack/                        # hand-written Helm chart
│   │   ├── files/                                # synced copy of config/, gated in CI
│   │   └── scripts/                              # synced copy of scripts/, gated in CI
│   ├── kind/kind-cluster.yaml                    # three-node local cluster
│   ├── images/init-tools/                        # toolchain image for the init jobs
│   └── README.md                                 # Compose-to-Kubernetes object map
├── terraform/eks/                                # SEPARATE OpenTofu module for the cluster
└── docs/
    └── otlp-logs-rollout.md                      # logs-not-appearing playbook
```

> `k8s/charts/lgtm-stack/files/` and `scripts/` are **copies**, and that is not duplication
> by accident. Helm cannot read a file outside its own chart directory, so the configs are
> copied in and `.github/workflows/helm-check.yml` fails the build when the copy drifts.
> `config/` and `scripts/` stay the single source of truth.

---

## Developer-assistance tooling

`.clinerules` and `memory-bank/` are **developer-assistance tooling** used while building
this experiment (project intelligence and a persisted "memory bank" for an AI coding
assistant). They are **not part of the observability stack** and have no runtime effect —
you can ignore or delete them when adapting this repo.

---

## Clone

```bash
git clone git@github.com:youruser/lgtm-stack-experiment.git
```
