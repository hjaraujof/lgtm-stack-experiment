# LGTM Stack: Disk-Full RCA + Production-Grade Architecture Study

**Created:** 2026-06-30
**Status:** Incident resolved (triage); architecture decisions open
**Incident:** Grafana inaccessible — EC2 root disk 100% full for 7+ days
**Host:** a single t3a.xlarge with a ~150 GB gp3 root volume

> This document supersedes the generator-leak hypothesis that was investigated and **disproven by live measurement**. It folds in an adversarial architecture study (20 agents, 12 verification passes) **and** the completeness-critic corrections. Every number here is anchored to runtime observation, not the source research (which contained fabricated cost/rate figures, since discarded).

---

## 1. What actually happened (corrected root cause)

The disk filled because **Tempo's compactor-managed trace store (`/var/tempo/blocks`) grew to fill most of the volume** under a long retention window with 100% (unsampled) trace ingestion — **not** from a traffic burst, **not** from the metrics-generator local-blocks path, and **not** from Loki/Mimir.

### Live measurement (the authoritative evidence)

Run this first. It settles the question in one command, and it is the step the
original hypothesis skipped:

```
sudo du -h -d2 /var/lib/docker/volumes/ | sort -h
```

The shape to look for: the Tempo volume dominates, and inside it `/blocks`
dominates, while `/wal` and `/generator` are orders of magnitude smaller. The
other backends' volumes are negligible by comparison. Check the container JSON
logs separately (`du -h /var/lib/docker/containers/*/*-json.log`) — an unrotated
one can be the second-largest consumer on the disk.

### Why it grew (the chain)

1. **Retention was deliberately lengthened without sizing the disk.** Prior plan `2025-11-28-lgtm-stack-storage-retention-fixes.md` raised Tempo `block_retention` from **1h → 336h (14 days)** to stop "trace data loss." Current config is `72h`. Either way, retaining 100% of spans for days produces a steady-state `/blocks` size that can exceed the volume it sits on. Retention is a disk-sizing decision; changing one without the other is the bug.
2. **No sampling.** OTel Collector traces pipeline is `[memory_limiter, batch] → 100% to Tempo`. Live logs show `LIVE_TRACES_EXCEEDED: per-user traces limit (local: 10000)` *immediately on restart* — the ingest firehose is real and substantial.
3. **No disk alarm.** The disk sat flat at 100% for **7+ days undetected** (CloudWatch confirmed). There was no alarm on `disk_used_percent` for this instance.
4. **No Docker log rotation.** `docker-compose.yml` sets no `logging:` limits, so a single container log can grow to gigabytes with nothing to stop it.
5. **Full disk broke the recovery tool.** At 100%, the SSM agent could not write its working files; `send-command` and `start-session` both failed (`Standard_Stream not found`). Recovery required **EC2 Instance Connect** (temporary SSH key) — note this *also* writes to disk, so it is not fully disk-full-proof; the durable mitigation is never reaching 100% (alarm + headroom).

### Corrected myth table

| Claim | Verdict | Evidence |
|---|---|---|
| Burst traffic caused it | **FALSE** | CPU climbed monotonically 7%→49% over 14d (steady, not spiky); disk flat at 100% for 7d |
| Generator `local-blocks` is the unbounded leak | **FALSE** | `du` shows `/generator` in the tens of MB. The bulk is in `/blocks` |
| "44 GB/day" ingest rate | **FABRICATED** | Back-derived from 133 GB ÷ 72h; not measured. 133 GB accrued over ~4.5 months. **Measure real growth before sizing anything** |
| Loki/Mimir are growth constraints | **FALSE** | loki-data 28 KB, mimir-data 4 GB |
| Removing `local-blocks` is the "$0 fix" | **FALSE for this incident** | Reclaims ~15 MB. Does not solve `/blocks` growth |

---

## 2. Immediate stabilization — DONE (2026-06-30)

| Action | Result |
|---|---|
| Truncated the oversized tempo container JSON log (`: > <log>`) | Freed enough to get off 100% |
| Deleted `/blocks` + `/wal` by **explicit name** (glob `*` failed — dir owned by UID 10001, unreadable to ec2-user so the shell expanded `*` to nothing under `sudo`) | Disk **143 GB → 11 GB used (7%)** |
| Force-recreated the Tempo container (`docker-compose rm -sf tempo && up -d --force-recreate`) — it was a zombie (`Up 8 days` but process dead, refusing :3200) | Tempo `Up (healthy)`, `/ready`=ready, `/api/search/tags` returning data → **Grafana Explore "Query error" resolved** |
| Created CloudWatch alarms `disk_used_percent` @75% (warn) + @90% (crit) → SNS `dev-alerts` (Teams + email) | Both **OK**; closes the silent-fill gap |

**Verified restored:** Grafana HTTP/2 200, app files load, `/api/health` database ok, SSM agent recovered, disk 7%.

**Caveat:** the trace store was wiped — traces older than ~2026-06-30 17:21 UTC are gone (acceptable; past dev value). New traces are ingesting and queryable.

> ⚠️ **This is triage. Nothing structural changed.** At the observed ingest rate, `/blocks` will refill. The disk alarm now buys days of warning, not a fix.

---

## 3. Operational paths & facts (corrected for THIS deployment)

The source study assumed bind-mounts (`./data/tempo`). **Reality: named Docker volumes.** Correct paths:

- Tempo data: `/var/lib/docker/volumes/lgtm_stack_tempo-data/_data/{blocks,wal,generator}`
- Root device: `nvme0n1p1`, **xfs** (so `tune2fs -m` does NOT apply — xfs has no equivalent reserve; size with headroom instead)
- Docker command on EC2: `docker-compose` (hyphen, v5.0.2)
- Break-glass when disk is full / SSM dead: **EC2 Instance Connect** (AZ `us-east-1a`, port 22 open, public IP):
  ```bash
  ssh-keygen -t rsa -f /tmp/k -N "" -q && \
  aws ec2-instance-connect send-ssh-public-key --instance-id i-0123456789abcdef0 \
    --instance-os-user ec2-user --availability-zone us-east-1a --ssh-public-key file:///tmp/k.pub && \
  ssh -o IdentitiesOnly=yes -i /tmp/k ec2-user@203.0.113.10
  ```

---

## 4. Security findings

These are the checks worth running against any single-host LGTM deployment.
They are stated as a checklist, not as the audit result of a live instance.

| Check | Severity if it fails | Why it matters |
|---|---|---|
| Is SSH (port 22) reachable from `0.0.0.0/0`? | **HIGH** | The whole internet can reach SSH. Restrict to a trusted CIDR via `ssh_ingress_cidr`, or close 22 entirely and use SSM Session Manager, which needs no inbound port. |
| Is `auth_enabled: false` on Tempo, Loki or Mimir? | MEDIUM | Anyone who reaches the OTLP or query ports gets unauthenticated read and write over all telemetry. VPC-scoping the ports bounds the blast radius to the VPC, it does not remove the exposure. |
| Is the Grafana admin password a hardcoded default? | MEDIUM | A default is live in the window before any init container rotates it, and that window is on the public internet if NGINX is up. Inject it from the environment with no fallback. |
| Is the Docker socket mounted into a container? | MEDIUM | Container escape to host root. The certbot container is the usual offender. |
| Are 80 and 443 open to `0.0.0.0/0`? | OK/expected | Public Grafana behind NGINX SSL. |
| Are OTLP 4317/4318, Grafana 3000 and Tempo 3200 scoped to the VPC CIDR? | OK if yes | These must never be public. |

---

## 5. Target architecture (tiered) — costs verified

**Costing basis** (AWS list prices, us-east-1): gp3 = **$0.08/GB-mo** flat, so 150 GB = **$12/mo**. Compute t3a.xlarge ≈ **$109/mo**. S3 Standard = $0.023/GB-mo. **Same-region EC2↔S3 transfer = $0** (public subnet + IGW; no NAT exists — the source study's "$1,980/mo NAT" and "$50-100/mo egress" were fabricated). An **S3 Gateway VPC Endpoint is free**.

### Tier 1 — Hardening on current EC2 *(recommended immediate end-state)*
- **Changes:** retention reduction (decision #2 below) OR add sampling; Docker log rotation; disk alarm ✅(done); grow EBS or attach dedicated data volume with headroom.
- **Cost:** 250 GB gp3 = $20/mo (Δ +$8). Total ≈ **$129/mo** ($109 compute + $20 disk).
- **Fidelity:** none lost (if you keep 100% ingest and just bound retention/disk).
- **Does NOT protect against:** single-host / single-AZ failure; future ingest growth.

### Tier 2 — S3 object-storage backends + free VPC endpoint *(recommended production step)*
- **Changes:** Tempo `storage.trace.backend: s3`; Mimir blocks+ruler+alertmanager → s3; Loki via a **new `schema_config` period** (future `from:` date, `object_store: s3`) keeping the old filesystem period so pre-cutover logs stay queryable. Add free S3 Gateway endpoint, scoped IAM instance profile, **mandatory S3 lifecycle expiration** as the compactor-stall backstop.
- **Cost:** S3 ~$2-3/mo storage + <$5/mo requests + $0 transfer; EBS can shrink (new volume; gp3 can't shrink in place). **≈ cost-neutral.**
- **Fidelity:** none lost (100% at full cardinality; modest cold-read latency on old blocks, mitigated by native caches).
- **Note:** S3 does **not** fix the `/blocks` retention sizing — pair with Tier 1 retention/sampling decision. Stage: **Tempo first**, then Mimir, then Loki.
- **Risk:** silent IAM-write failure (ingesters stop flushing without crashing). Pre-validate with `aws s3 cp`, enable S3 access logging, alert on `tempodb_compaction_outstanding_blocks`.

### Tier 3 — EKS distributed or managed SaaS *(NOT recommended now)*
- EKS realistic **$350-550/mo** (no Kafka needed for distributed Tempo 2.6.1; the source's Kafka line was fabricated), heavy ops for team size.
- Grafana Cloud / X-Ray / CloudWatch **rejected** — per-span/per-GB billing forces sampling → violates the no-fidelity goal + lock-in.

---

## 6. Reliability gaps to close (from completeness critic)

- **HA/DR:** Tier 1/2 are single-host, single-AZ. An AZ outage = total observability blackout *during the incident you need it for*. Named volumes sit on the root EBS → **any instance replacement = total telemetry loss** unless state is on S3/persistent volume first. Decide if single-AZ is acceptable (see #5 below).
- **Backups:** none today. Add scheduled EBS snapshots and (Tier 2) S3 versioning. `grafana-data` (dashboards/users/API keys) has **no backup** — losing the root volume loses all dashboards.
- **Self-monitoring / dead-man's-switch:** the disk alarm dies with the host. Add an **external** check that survives total host failure (Route53 health check on the Grafana endpoint, or CloudWatch `StatusCheckFailed` / metric-absence alarm).
- **Compactor-stall risk applies to current filesystem Loki/Mimir too**, not just S3 — Loki retention is enforced only by its compactor; if it stalls, Loki grows unbounded (same failure class as this incident).
- **otel-collector** has no healthcheck and no memory limit (scratch image); it is the ingest chokepoint and a reliability risk. No container has resource limits — the June 21 98%-memory spike is unexplained and an OOM hazard.
- **Validation window:** after any retention/leak change, watch the volume for ≥1× `complete_block_timeout` (15m) + compaction window (1h) before declaring success; 48h flat is the real confidence bar.

---

## 7. Open decisions (human-only forks)

1. **Budget ceiling** — recommended path is cost-neutral to ~$129/mo; EKS is a real $350-550/mo step. Is Tier 3 ever on the table?
2. **Trace retention window** — currently 72h. What MTTR/debugging window does the team need? This drives disk/S3 sizing. (Longer is cheap on S3, expensive on EBS.)
3. **Sampling tolerance** — no-fidelity is satisfiable by retention+disk alone. If ingest grows, is **tail sampling** (always keep errors + slow traces) acceptable, or must 100% ingest be permanent? If sampling: compute span/RED metrics **before** sampling so they aren't biased.
4. **Managed vs self-hosted** — self-hosted keeps fidelity but you operate it; SaaS removes ops but forces sampling. Recommendation: self-hosted. Confirm.
5. **HA requirement** — is single-AZ/single-host acceptable for this workload, or is multi-AZ HA required (forces Tier 3)?
6. **Who operates it** — Tier 1/2 stay within docker-compose range; Tier 3 needs ≥1 SRE. Is "no Kubernetes" a hard constraint?

---

## 8. Sequenced roadmap

**Phase 1 — Stabilize (DONE + finish):** ✅ disk recovered, ✅ alarms live. Remaining: Docker log rotation; decide+apply retention/sampling so `/blocks` can't refill the disk; size EBS with headroom.

**Phase 2 — Safety nets (week 1-2, ~cost-neutral):** container mem/CPU limits; measure true daily growth of `/blocks` + Mimir (replace fabricated 44 GB/day); compaction-lag + per-component disk alerts; external dead-man's-switch; EBS snapshot schedule; restrict SSH ingress; rotate Grafana admin.

**Phase 3 — Replatform to S3 (weeks 3-5, ~cost-neutral, if chosen):** bucket + free Gateway endpoint + scoped IAM; migrate Tempo → Mimir → Loki (new schema period); lifecycle expiration; new (smaller) EBS; clean up orphaned data.

---

## 9. Rollback

- Disk alarms: `aws cloudwatch delete-alarms --alarm-names "LGTM-Stack - Disk Space WARNING (75%)" "LGTM-Stack - Disk Space CRITICAL (90%)"`
- Any retention/sampling config change: revert the YAML line and `docker-compose up -d --force-recreate <svc>`.

---

## Related

- `.claude/plans/2025-11-28-lgtm-stack-storage-retention-fixes.md` — the retention increase (1h→336h) whose unsized disk impact led to this incident.
