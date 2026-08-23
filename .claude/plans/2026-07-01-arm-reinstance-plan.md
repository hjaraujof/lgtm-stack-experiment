# ARM (c7g) Re-instance Plan — DEFERRED / OPTIONAL

**Created:** 2026-07-01 | **Status:** PLAN ONLY — nothing to apply; execute only if the cost case is approved
**Starting point:** a **t3a.2xlarge (x86, 8 vCPU/32GB)** running comfortably below capacity.

## TL;DR — should we even do this?
**Not urgent, arguably not worth it right now.** The original c7g ARM plan predates the resize + S3 + per-service sampling. Since then: CPU pressure is gone, disk-full is structurally eliminated (S3), and Tempo idles. **ARM's only remaining benefit is cost** (Graviton ~20% cheaper), and the move is a **destructive cross-arch REPLACE** with real (if now-small) data-loss surface. Recommendation: **defer unless the ~$40-50/mo Graviton saving is being actively pursued**, or bundle it with a future maintenance window. This plan exists so it can be executed safely *if* chosen.

## Cost delta (rough, us-east-1 on-demand)
- Baseline: t3a.2xlarge ≈ **$0.301/hr ≈ $220/mo** at list price (+ ~150GB gp3 $12/mo).
- Target: c7g.2xlarge ≈ **$0.29/hr ≈ $212/mo** — barely cheaper on-demand. The real win is a **1yr Compute Savings Plan** (~40% → ~$130/mo) which *also* covers t3a. So ARM's marginal saving over a Savings-Plan'd t3a is small. **Confirm actual Graviton-vs-x86 Savings-Plan rates before committing** — the case may be weaker than assumed.

## What survives vs is lost (cross-arch = ForceNew REPLACE, fresh root EBS)
| Data | On S3? | Survives replace? |
|---|---|---|
| Tempo trace blocks | ✅ yes | ✅ (backend=s3; new box re-discovers) |
| Mimir metric blocks | ✅ yes | ✅ (backend=s3) |
| **grafana-data** (50M, `grafana.db`) | ❌ | ❌ LOST — but the 13 demo-service dashboards + datasources are **provisioned from files (in git)** so they auto-restore. Only UI-created dashboards / API keys / service-account tokens / annotation history are lost. |
| **loki-data** (28K) | ❌ | ❌ LOST — trivial (logs go to CloudWatch anyway). |
| Tempo WAL + local scratch | n/a | ❌ LOST — only in-flight, ~seconds of data. |

Net: with S3, **telemetry survives**. Real loss = Grafana UI-created state (mint a fresh admin token after; provisioned dashboards are fine) + the sub-minute WAL. Take an EBS snapshot first as belt-and-suspenders.

## Pre-flight gates (all must pass)
1. **arm64 images** — all 5 confirmed multi-arch earlier (tempo 2.6.1, loki 3.3.2, mimir 2.14.1, grafana 12.3.0, otel-collector-contrib 0.142.0 — the collector was VERIFIED to have linux/arm64 despite an earlier false claim). Re-check at execution: `for i in <images>; do docker manifest inspect $i | grep -q arm64 && echo "$i OK"; done`.
2. **`user_data.tpl` buildx fix (REQUIRED)** — line 30 hardcodes `buildx-...linux-amd64` → 404s on arm64 → grafana-init build fails → bring-up aborts. Fix before apply:
   ```bash
   # user_data.tpl line 30 — arch-map (buildx uses GOARCH names, not uname -m):
   ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; esac
   sudo curl -SL "https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION.linux-$ARCH" -o /usr/local/lib/docker/cli-plugins/docker-buildx
   ```
   (Line 18 docker-compose download already uses `$(uname -m)` which ships an `aarch64` asset — leave it.)
3. **Export Grafana UI state** if any UI-created dashboards/keys matter (provisioned ones are safe): back up `grafana.db` or export via API before the replace.
4. **c7g.2xlarge available in us-east-1a**: `aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=c7g.2xlarge Name=location,Values=us-east-1a`.

## Execution (only after gates pass)
1. **EBS snapshot** of the root volume (belt-and-suspenders; S3 already holds telemetry):
   `aws ec2 create-snapshot --volume-id <root-vol> --description "pre-c7g-arm $(date -u +%FT%TZ)"` — wait for `completed`.
2. **main.tf edits:**
   - arch filter `values = ["x86_64"]` → `["arm64"]` (line ~213)
   - **temporarily remove `lifecycle { ignore_changes = [ami] }`** (lines 255-262) so the new arm64 AMI is picked up (else the replace won't see it).
   - keep `root_block_device` as-is (or add `delete_on_termination = false` to retain the old vol as an extra recovery handle).
3. **Secrets Manager:** `instance_type` `t3a.2xlarge` → `c7g.2xlarge`.
4. **`tofu plan` and READ IT** — expect exactly `aws_instance.lgtm_instance` **must be replaced** (AMI + type change) + Route53 A record update to the new IP. Confirm NOTHING else is destroyed.
5. **`tofu apply`** — new arm64 c7g boots, `user_data` runs (with the buildx fix), clones repo, `docker-compose up`. Tempo/Mimir come up on S3 and re-discover blocks.
6. **Re-pin the AMI:** after the apply resolves the arm64 AMI, restore `lifecycle { ignore_changes = [ami] }` (or pin `data.aws_ami` to the exact resolved ID with `most_recent=false`) so future applies don't re-replace. Commit.
7. **Restore Grafana admin token** if it was UI-created; verify provisioned dashboards loaded.

## Validation
- `uname -m` = `aarch64`; all 7 containers Up + healthy; `docker images` show arm64 digests; `grafana-init` exited 0 (proves buildx worked).
- Grafana HTTP/2 200; demo-service dashboards present (provisioned); Tempo `/ready`; a pre-existing trace resolves from S3 (proves S3 read on the new box).
- Bleed 0; load reasonable; disk alarms still OK (they're Metrics-Insights InstanceId-based, so they survive the type change — no re-break this time).
- **NEW public IP** → confirm Route53 propagated (`grafana.example.com` resolves to new IP).

## Rollback
Revert `instance_type` → `t3a.2xlarge` and arch filter → `x86_64` (pin to last-good x86 AMI), `tofu apply` (another REPLACE — safe because S3 + snapshot). Never `tofu destroy`. If the new box never came healthy, the retained old EBS (if `delete_on_termination=false` was set) or the snapshot restores state.

## Risks
| Risk | Mitigation |
|---|---|
| Cross-arch replace destroys root EBS | S3 holds telemetry; EBS snapshot; provisioned dashboards in git |
| buildx amd64 → grafana-init fails | user_data.tpl arch-map fix (gate #2) — HARD gate |
| An image lacks arm64 | pre-flight manifest check (gate #1) |
| Future apply re-replaces (AMI drift) | re-pin ignore_changes/exact AMI post-apply |
| New IP breaks access mid-cutover | Route53 auto-updates; SSM works regardless (no SSH needed) |
| Grafana UI state lost | export/snapshot grafana.db first; provisioned config unaffected |

## Bottom line
Executable and safe *if* the cost case justifies it, but **a healthy t3a.2xlarge plus a Savings Plan captures most of the saving without the migration risk.** Recommend deferring unless Graviton cost optimization is an explicit goal.
