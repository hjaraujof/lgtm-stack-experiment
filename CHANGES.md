# Mirror & Org-Agnostic Sanitization — Change Log

---

## Second mirror pass — alerting, SLOs, runbooks, tests and CI

A second port from the same internal source, covering the work done there after the first mirror.
Same sanitization contract as §3 below, extended with three rules the first pass did not need.

### What was ported

| Area | Detail |
|---|---|
| Alert rules | 7 alerts → **31**; 10 recording rules → **16**. New: `slo-burn.yaml` (multi-window burn rate, auth-failure SLI, latency SLI, coverage tripwire, per-service absence), and in `stack-alerts.yaml` the per-endpoint total-failure alert, pipeline floors, application-metrics detector, Tempo/Loki discard tripwires with catch-alls, spanmetrics burst-limit predictor, and the alert-path integrity trio (`AlertDeliverySilent`, `AlertmanagerConfigChanged`, `Watchdog`) |
| Alertmanager | severity-split receivers, inhibition scoped to an explicit allowlist, a dedicated unsubscribed watchdog topic, and templates that split `.Alerts.Firing` from `.Alerts.Resolved` |
| Config deploy | `ruler_storage.backend=local` over a read-only bind mount, so `git pull` deploys rules; `scripts/init-mimir-alertmanager.sh` reconciles the Alertmanager config on a loop and reverts out-of-band writes |
| Runbooks | `docs/runbooks/` — one per alert, linked from each rule's `runbook_url` |
| Tests | 5 promtool rule-unit-test suites; `tests/scripts/test-am-reconcile.py` (a real socket, the real wire format, and its own **negative control**) |
| CI | `mimir-rules-check.yml` and `config-check.yml`, each validator paired with a **positive control** that asserts rejection of a broken config |
| Stack config | collector (`resource_metrics_key_attributes`, `metrics_expiration`, span-name templating, internal-telemetry scrapes, persistent queue, hostmetrics, app-metrics `service_name`), Mimir (explicit series cap, burst size, cardinality API, ruler poll), Tempo 3.x migration + `max_attribute_bytes`, Loki `max_structured_metadata_size` |
| Dashboards | `services/service-red.json` (golden-path template) and `lgtm-health/lgtm-stack-health.json` — both were already free of org tokens |
| nginx | per-request upstream re-resolution, and write guards on the Grafana-proxied ruler and Alertmanager config paths |
| Terraform | two resources only — the watchdog SNS topic and the CloudWatch alarm on its publish count. The `Watchdog` alert is a defect without them. |

Verified locally, not asserted: all 47 rules pass `promtool check rules`; all 5 test suites pass
`promtool test rules`; the reconciler test passes all 14 checks including its negative control; the
collector, Loki, Mimir and Tempo configs pass their own validators; `amtool check-config` passes;
`nginx -t` passes on both server configs; `docker compose config -q` resolves; every `scripts/*.sh`
passes `bash -n`; `tofu fmt -check` passes.

### Three sanitization rules this pass added

The first pass replaced *identifiers*. Alert rules leak in three further ways, none of which a token
substitution catches:

1. **Measured operational figures are org data.** A comment that quantifies real traffic — volume
   lost over a window, the read rate of a named service, the share of total volume an environment
   carries, the failure rate during an outage — describes a private system's traffic shape and
   incident history. Every such figure was replaced with the *shape* of
   the finding ("a large fraction", "orders of magnitude", "a residual trickle"). Threshold
   arithmetic that is self-contained and re-derivable was KEPT — e.g. "each label combination costs
   (buckets + 3) samples per flush", and the standard-error derivation behind a sample-count gate.
2. **Incident dates and ticket keys were dropped, not renamed.** A dated narrative ("on \<date\>
   the config was wiped") is a timeline of a private outage. The engineering content — *why*
   `absent()` is load-bearing, *why* two lookbacks must differ — is stated as a general failure mode
   instead. Internal ticket keys were removed rather than mapped to `PROJ-XXXX`, which would be noise
   in a public repo.
3. **Test fixtures name services.** Rule unit tests need concrete `service_name` values, so they use
   `tenant-a`/`tenant-b`/`tenant-c` with generic components (`orders-api`, `auth-api`, `web-portal`).
   Public framework names (Next.js, OTel semconv) were **kept**: they are public technical facts that
   help the reader and reveal nothing about the business.

### Deliberately NOT ported

| Dropped | Reason |
|---|---|
| Pyroscope box (`pyroscope.tf`, its compose file, config and bootstrap) | The source states the Terraform **has never been applied** and the datasource was retracted as dead. A reference repo must not ship unexercised code. |
| Fleet OTel-endpoint audit script | Walks a specific cloud account's container clusters by client. Pure org topology; no generic value. |
| Daily trace-error report (644 lines) | Carries a benign-error allowlist naming internal services, an internal topic and a secret path. Its one transferable idea — reset-segmented counting, because `increase()[24h]` re-extrapolates across every counter reset — is preserved as a comment on `metrics_expiration` instead. |
| GitHub-OIDC **plan** role and its runbook | A manual procedure against a named IAM role in one account. The **publish** role is ported, because the S3 boot path depends on it — see `docs/runbooks/bootstrap-publish-role.md`. |
| `grafana-ssl.conf` | A pre-rendered copy of `grafana.conf.template` with one domain hard-coded. Two copies of the same write guards must be kept in step, a hazard the source repo records having been bitten by, and a fixed domain does not suit a reusable repo. Instead the template is rendered on the host at deploy time by `scripts/render-nginx-ssl.sh`, which removes both the second copy and the manual `docker exec` step. |
| Internal planning docs, incident forensics, presentations, profiling scripts | Private architecture and cost figures. |

### Two honest gaps in what was ported

- **The provisional thresholds are still provisional.** The 1% error budget, the two pipeline floors,
  and the Mimir series cap are placeholders calibrated against a system that is not yours. The
  multi-window structure and the multipliers are the part that transfers. Each is flagged in place.
- **`ingestion_burst_size` and `MimirActiveSeriesHigh` remain mutually incoherent**, and the source's
  own comment says so: a whole-cache flush rejects at roughly 200k series while the series alert fires
  at 400k, so the series alert still cannot fire first. Ported as-is, with the incoherence documented
  rather than quietly smoothed over.

---

## First mirror pass

This section explains the change that expanded `lgtm-stack-experiment` from a
minimal 9-file local LGTM stack into a full-featured, **org-agnostic** reference stack,
mirrored from an internal, org-specific source repository.

> **TL;DR** — The internal source repo grew a lot of production hardening (AWS/Terraform,
> NGINX + TLS, S3-backed storage, recording rules + alerting, tail sampling, dashboards,
> user provisioning). Those improvements were ported here and **every org-specific
> identifier was replaced with a generic placeholder** so this repo can live in the open
> without leaking any private infrastructure, service topology, or personal data.

---

## 1. What this repo was, and what it is now

| | Before (this repo) | After |
|---|---|---|
| Tracked files | 9 | 118 |
| Surface | Local docker-compose only (5 configs + compose + README) | Local stack **plus** optional AWS deploy, TLS, S3 storage, alerting, dashboards, user provisioning, test tooling, and reference `.claude/` docs |
| Identifiers | already generic | all generic placeholders (verified, see §4) |

The repo keeps its original **identity and intent**: a self-contained, reference LGTM
stack you can stand up locally in seconds. Nothing that made it approachable was removed —
the new material is additive and every deployable value is a placeholder.

---

## 2. What was mirrored (by area)

### Local stack (the core — refined, not replaced)
The five backend/collector configs, `docker-compose.yml`, and Grafana datasource
provisioning were updated to the source's newer versions:

- **`config/otel-collector-config.yaml`** — adds a `spanmetrics` connector that computes
  RED metrics on **100 % of traffic before sampling**, a **tail-sampling** processor
  (keep errors/slow traces + important environments, sample high-volume traffic), and a
  Tempo `/metrics` scrape for early-warning signals.
- **`config/mimir-config.yaml`** — exemplar storage enabled; S3 blocks storage wired for
  the AWS path (falls back to local filesystem locally).
- **`config/tempo-config.yaml`** — local-blocks retention tuning; S3 backend for the AWS
  path; metrics-generator span-metrics/service-graph settings.
- **`config/loki-config.yaml`** — retention/limits refinements.
- **`config/grafana/provisioning/datasources/datasources.yaml`** — trace↔log correlation
  (derived `traceID` field), trace→metrics (RED), node-graph, and `tracesToLogsV2` wiring;
  Tempo pinned to `httpMethod: GET`.

### AWS deployment (new here)
- **`main.tf`** — single EC2 host, VPC/subnet/SG/IGW/route table, IAM instance role
  (CloudWatch + SSM), key pair + AMI data sources, Route 53 private hosted zone for
  internal OTLP DNS.
- **`s3-backends.tf`** — S3 buckets for Mimir metrics + Tempo traces object storage
  (bucket names derived from region + `aws_caller_identity` account id — fully portable).
- **`alerting.tf`** — SNS topic + CloudWatch alarms + SNS-publish IAM for host alerting.
- **`user_data.tpl`** — EC2 first-boot bootstrap: clone repo, render `.env` from Secrets
  Manager, bring the stack up with the SSL profile.
- **`.terraform.lock.hcl`** — provider lock (left byte-for-byte intact; hashes must not
  be altered).

### TLS / reverse proxy (new here)
- **`config/nginx/`** — `nginx.conf`, HTTP-only bootstrap `grafana-init.conf`, and the
  TLS `grafana.conf.template` (includes the proxy-buffer fix for Grafana's JS bundles and
  the `http2 on;` directive form).
- **`scripts/init-certbot.sh`, `scripts/renew-certs.sh`** — Let's Encrypt lifecycle.

### Grafana users & teams (new here)
- **`config/grafana/users-config.json`** — team + users, passwords sourced from a secrets
  store. Real users replaced with generic placeholders (see §3).
- **`scripts/init-grafana.sh`, `scripts/Dockerfile.grafana-init`** — idempotent
  provisioning container.

### Dashboards, recording rules, alerting (new here)
- **`config/grafana/provisioning/dashboards/demo-service/`** — 13 dashboards for a single
  neutral `demo-service` across `dev` / `qa` / `uat` / `prod` + a global overview
  (renamed and rewritten from the source's real, service-specific dashboards — see §3).
- **`config/mimir/rules/demo/red-recording.yaml`** — RED recording rules.
- **`config/mimir/rules/demo/stack-alerts.yaml`** — stack-health alerts (Mimir self-scrape,
  telemetry-gap detection).
- **`config/mimir/alertmanager/demo-am.yaml`** — demo Alertmanager routing.

### Host metrics & test tooling (new here)
- **`config/cloudwatch-agent-config.json`** — EC2 host metrics/logs collection.
- **`scripts/send-test-{traces,logs,metrics,telemetry}.sh`**, **`scripts/setup-local-env.sh`**.
- **`docs/otlp-logs-rollout.md`** — "logs not appearing" playbook.

### Reference `.claude/` material (new here, sanitized)
Agent definitions and their reference docs (OTel collector architecture, LGTM backends,
Grafana visualization, observability correlation, Terraform/AWS, docker-compose
orchestration, alerting/SRE patterns), reusable commands, `CLAUDE.md`, and infrastructure
plans/runbooks. These are generically useful observability/IaC references.

---

## 3. How it was made org-agnostic

Every org-specific identifier was replaced with a neutral placeholder, applied
consistently across all files. The mapping:

| Class | Internal value → | Placeholder |
|---|---|---|
| Public domain | company domain | `example.com` |
| Grafana host | internal Grafana FQDN | `grafana.example.com` |
| Internal DNS | internal OTLP DNS zone | `otel-collector.internal.example.com` / `internal.example.com` |
| AWS account | real 12-digit account id | `123456789012` (and, in S3, `aws_caller_identity` interpolation) |
| AWS resource ids | real instance / VPC / subnet / SG / route-table / volume / IGW ids | generic `…0123456789abcdef0` example ids |
| S3 buckets | org-prefixed metrics/traces buckets | `lgtm-{metrics,traces}-<region>-<account>` |
| TF state bucket | org state bucket | `example-terraform-state` |
| Secrets Manager | org-prefixed `/…/{dev,uat,prod}/lgtm-stack` | `/example/{dev,uat,prod}/lgtm-stack` |
| Emails / users | real employees + ops/devops addresses | `admin@example.com`, `editor1@example.com`, … |
| User display names | real first names | generic role names (`Admin User`, `Editor One`, …) |
| Service / tenant | real service + tenant codenames | `demo-service`, `tenant-a`, `tenant-b` |
| Environments | env slugs embedded in dashboards | `dev` / `qa` / `uat` / `prod` |
| Git remote | internal org/repo clone URL | `git@github.com:youruser/lgtm-stack-experiment.git` |
| Harness env vars | org-prefixed code-root / developer vars | removed; paths are repo-relative |
| Packages | `@<org>/instrumentation` etc. | `@your-org/instrumentation` |
| Project-mgmt keys | internal ticket keys | `TICKET-XXXX` |

### Files renamed
- The service-specific dashboards directory and its 13 `<service>-<env>-*.json` files were
  renamed to `config/grafana/provisioning/dashboards/demo-service/` and
  `demo-service-<env>-*.json`. Dashboard `uid` and `title` fields inside the JSON were
  updated to match.
- The dashboards planning doc under `.claude/plans/` was renamed from its service-specific
  name to `2025-12-01-demo-service-grafana-dashboards.md`.

### Content removed (not merely renamed)
Some source content described the origin org's **proprietary system** and had no generic
value, so it was dropped rather than genericized:

- **`.claude/docs/instrumentation-research/`** — a deep study of the origin org's specific
  microservice topology and third-party vendor integrations. Even fully token-scrubbed it
  would describe a private architecture, so it was removed entirely.
- **`.claude/docs/` presentations, speaker notes, cost analysis, presentation audit** —
  internal training/working artifacts referencing specific internal services and cost
  figures.
- **`.claude/plans/2025-12-01-observability-presentation-refinement.md`** — a plan whose
  sole purpose was building the (removed) internal presentation deck.
- **`.claude/sessions/`, `.claude/settings.local.json`, `.mcp.json` server entries,
  `graphify-out/`, `terraform.tfstate*`** — never mirrored (local/transient/private).

### Preserved from this repo
- `.clinerules` and `memory-bank/` (Cline developer-assistance tooling) — untouched and
  still git-ignored.
- The `.gitignore` was **merged**: the source's Terraform/env/backup ignore rules were
  combined with this repo's existing Cline + `data/` rules.

---

## 4. Verification

The sanitization was performed per file-group and then **adversarially verified** by an
independent pass that grepped the whole tree for each token class. Final full-tree sweep
(excluding `.git/`, `data/`, `memory-bank/`) returned **zero** hits for every one of:

```
the origin org's brand name · the real AWS account id · real instance/VPC/subnet/SG ids ·
real employee emails & first names · org-prefixed harness env vars · @<org>/ packages ·
the internal clone URL · internal service/tenant codenames ·
internal service & vendor names surfaced during review
```

Structural validity was also confirmed:

- **YAML** — all 10 config/compose/rule files parse (`yaml.safe_load`).
- **JSON** — `users-config.json`, `cloudwatch-agent-config.json`, and all 13 dashboards parse.
- **HCL** — `tofu fmt` parses and formats `main.tf` / `s3-backends.tf` / `alerting.tf` clean.
- **Shell** — all 8 `scripts/*.sh` pass `bash -n`.

> **Note:** placeholders are placeholders. Before deploying anything real, replace the
> account id, domains, DNS names, Secrets Manager paths, state bucket, users, and service
> names with your own values.
