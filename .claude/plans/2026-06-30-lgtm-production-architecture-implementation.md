# LGTM Production Architecture — Dependency-Ordered Implementation Plan

**Created:** 2026-06-30
**Status:** PLAN v2 — safety-critic blockers folded in; reviewed, NOT yet applied
**Operating model:** small team, `docker-compose` (v5.0.2) on a single EC2 host
**Supersedes the open architecture decisions in:** `.claude/plans/2026-06-30-lgtm-disk-full-rca-and-production-architecture.md`

> **v2 changelog (post adversarial safety-critique):** (1) Corrected the false "collector has no arm64" finding — `docker manifest inspect` confirms all 5 images have linux/arm64 (§0). (2) Fixed the invalid `tail_sampling`-as-connector pipeline topology → `forward` connector + processor (§4.4). (3) Added explicit grafana-data/loki-data loss scope + mandatory Grafana export pre-cutover (Phase 1). (4) Added the missing `user_data.tpl` buildx arch fix (§4.9). (5) Made the Phase-3 fidelity gate two-part (connector-rate flat AND stored-rate down) so it can actually detect the failure mode (§Phase 3). Open items #4 (SSH 0.0.0.0/0) and #8 (admin pw) confirmed at runtime: SSH SG IS 0.0.0.0/0; address early.

> Every snippet below is version-correct for the **pinned** versions: Tempo 2.6.1, Loki 3.3.2, Mimir 2.14.1, Grafana 12.3.0, otel-collector-contrib 0.142.0. Adversarial corrections from the design review are folded in directly — the flaws are NOT repeated. Where a reviewer disproved a design claim (e.g. cross-arch stop/start, `bucket:` for Mimir, `tracesToLogs` V1, Mimir exemplars-on-by-default, `telemetry.metrics.address`), this plan uses the corrected form and calls out why.

---

## 0. Anchored facts (do not contradict)

- **Baseline** for the worked example below: one t3a.xlarge (x86_64) with a 150GB gp3 root volume, in a public subnet behind an IGW, **no NAT**.
- **`instance_type` lives in Secrets Manager** `/example/dev/lgtm-stack` (read at `main.tf:226`). The **AMI is NOT pinned** — `data.aws_ami.latest_linux_2` uses `most_recent=true` (`main.tf:199-222`); `aws_instance.lgtm_instance.ami` (`main.tf:225`) is **ForceNew**.
- **Root volume has NO `delete_on_termination` set** (`main.tf:233-236`) → defaults to **`true`**. Any instance REPLACE destroys the 150GB root EBS and all named volumes on it.
- **Named Docker volumes on root EBS**: `lgtm_stack_tempo-data`, `lgtm_stack_mimir-data`, `lgtm_stack_loki-data`, `lgtm_stack_grafana-data` under `/var/lib/docker/volumes/<name>/_data`. Root fs is **xfs on nvme0n1p1**.
- **The load shape that motivates this plan:** Tempo and the otel-collector each consuming most of a vCPU-pair, saturating a 4-vCPU box, while memory sits well under half. CPU-bound, not memory-bound — and on a burstable instance that means the credit balance drains. Measure your own with `docker stats` and the `CPUCreditBalance` CloudWatch metric before you size anything.
- **Active data loss:** `tempo_discarded_spans_total{reason="live_traces_exceeded"} = 23.2M`. `local_blocks max_live_traces=10000` cap hit. span-metrics = 0 live series (generator starved).
- **Disk root cause:** the bulk of the volume in Tempo `/var/tempo/blocks` (compactor-managed, 72h `block_retention`), NOT the generator path. 100% ingest, no sampling. At that rate a full-size volume refills in days, so freeing space without changing retention or sampling only buys a short reprieve.
- **CloudWatch disk alarms @75%/@90% already exist** → SNS `lgtm-stack-alerts` (email confirm pending).
- **Grafana provisioned datasources are file-based** (`./config` mount, in git) so they survive re-instance. All other state (telemetry, Grafana UI-created users/keys) is on the root EBS.

### arm64 image availability — VERIFIED (corrects a workflow false-positive)

An intermediate review *asserted* `otel/opentelemetry-collector-contrib:0.142.0` had no `linux/arm64` manifest. **This was wrong.** `docker manifest inspect` on 2026-06-30 confirmed **all five** pinned images publish `linux/arm64`:

| Image | linux/arm64 |
|---|---|
| grafana/tempo:2.6.1 | ✅ |
| grafana/loki:3.3.2 | ✅ (+ arm) |
| grafana/mimir:2.14.1 | ✅ |
| grafana/grafana:12.3.0 | ✅ (+ arm) |
| otel/opentelemetry-collector-contrib:0.142.0 | ✅ (also 386, amd64, arm, ppc64le, riscv64, s390x) |

**There is no image blocker for the ARM (c7g) move.** Phase 1 still keeps a cheap `docker manifest inspect` re-check as a pre-flight (defends against a future re-pin), but it is expected to pass. The real ARM gates are the `user_data.tpl` buildx fix (§4.9) and `grafana-init` building locally on arm64 — both addressed.

---

## 1. Goal & end-state

A single-host, docker-compose LGTM stack on **c7g.2xlarge** (ARM Graviton3, 8 fixed vCPU / 16GB — fixed-performance, **no CPU credits**), with **Tempo and Mimir trace/metric blocks stored in S3** via a free S3 Gateway VPC Endpoint and a scoped IAM instance profile (mandatory lifecycle-expiration backstop), **full-fidelity span-RED + service-graph + TraceQL metrics computed on the 100% pre-sample stream**, and **tail-sampling applied only to what is STORED as traces** (keep 100% of errors/slow/DB-touching, probabilistic baseline for the rest). All correlation features (C1 trace→logs via `tracesToLogsV2`, C2 logs→trace, C3 trace→metrics, C4 exemplars, C5 service map/node graph) and alerting (D1-D4: tail sampling, exemplar emission, Mimir/Loki/Grafana rulers, recording rules) are enabled, plus stack self-health and an external dead-man's-switch that survives total host failure. At list prices this lands **≈ $215/mo on-demand, or ≈ $140/mo with a 1-yr Compute Savings Plan** — close to neutral against the t3a.xlarge baseline, for a more capable and more durable stack.

---

## 2. Dependency graph

```
                         ┌─────────────────────────────────────────────┐
                         │ Phase 0: interim bleed-stop                  │
                         │ raise max_live_traces (Tempo, in place)      │  no deps; reversible
                         └───────────────┬─────────────────────────────┘
                                         │ (independent — can ship today)
                                         ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │ Phase 2: S3 backends (Tempo+Mimir) + free Gateway endpoint + scoped IAM        │
   │   IAM/S3/endpoint MUST exist & be pre-flight-validated (aws s3 cp from EC2)     │
   │   BEFORE flipping any backend to s3. Same-arch, no re-instance required.        │
   │   ⇒ makes re-instance SAFE: committed blocks survive on S3.                     │
   └───────────────┬────────────────────────────────────────────────────────────────┘
                   │ (S3 cutover proven ⇒ EBS data is now disposable)
                   ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │ Phase 1: re-instance t3a.xlarge(x86) → c7g.2xlarge(arm64)                       │
   │   CROSS-ARCH ⇒ NOT a stop/start. New AMI = Terraform ForceNew = volume DESTROY. │
   │   Requires: arm64 AMI + collector arm64 image gate + EBS snapshot of 4 volumes  │
   │   (belt-and-suspenders on top of S3) + pin AMI / ignore_changes[ami].           │
   └───────────────┬────────────────────────────────────────────────────────────────┘
                   │ capture latency baseline on the new (8-vCPU) box
                   ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │ Phase 3: generator-on-FULL-stream  +  tail-sampling on STORED traces only       │
   │   HARD ORDERING INVARIANT (see §5): span-metrics/service-graphs generated from   │
   │   100% stream; collector samples ONLY the path that writes trace blocks.         │
   └───────────────┬────────────────────────────────────────────────────────────────┘
                   │ metrics confirmed unbiased (rate unchanged across cutover)
                   ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │ Phase 4: correlation features C1-C5 (datasources.yaml + Mimir exemplar storage) │
   └───────────────┬────────────────────────────────────────────────────────────────┘
                   ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │ Phase 5: alerting + recording rules + stack self-health + dead-man's-switch     │
   └────────────────────────────────────────────────────────────────────────────────┘
```

**Why this order differs from the naive sequencing in the brief.** The brief's "Phase 1 re-instance, then Phase 2 S3" ordering is *unsafe* for a cross-architecture move:

1. **S3 must come before re-instance, not after.** Cross-arch (x86→arm) cannot be a stop/start of the existing volume — the root filesystem and kernel are x86 and will not boot on Graviton. Cross-arch **requires** a new arm64 AMI, which is a Terraform `ForceNew` REPLACE, which **destroys the root EBS and all four named volumes**. Migrating Tempo+Mimir blocks to S3 first means the committed telemetry survives the re-instance; only un-flushed WAL/TSDB is lost. (We additionally snapshot the volumes as belt-and-suspenders.) The reviewers proved both the "stop/start preserves data across arch change" claim and the "terraform apply doesn't replace the instance" claim FALSE; this reordering is the fix.
2. **Generator-on-full-stream before tail-sampling** (and both before correlation validation): span-metrics/service-graphs/TraceQL-metrics MUST see 100% of spans or every RED/service-map panel is understated by the sample fraction. §5 pins the exact topology.
3. **S3 IAM before S3 backend cutover**: a misconfigured policy makes ingesters silently stop flushing (no crash). The pre-flight `aws s3 cp` from the instance and CloudTrail/backend-metric detection gate the cutover.

Phase 0 is independent of everything and ships immediately to stop the 23.2M-and-counting bleed while the rest is built.

---

## 3. Phased rollout (each phase independently shippable + reversible)

### Phase 0 — Interim bleed-stop (raise `max_live_traces`)  — TODAY, in place

**Goal:** stop `live_traces_exceeded` discards now, on the current t3a box, without re-instancing.
**Change:** `config/tempo-config.yaml` `metrics_generator.processor.local_blocks.max_live_traces: 10000 → 25000` (conservative; memory is only ~28-30% used and the generator path is ~15MB on disk). Do **not** jump to 50000 on the 4-vCPU box — the "200KB/live-trace" figure is unverified; 25000 is a measured-headroom step, and the real fix is the re-instance + sampling.
**Apply:** `docker-compose up -d --force-recreate tempo`
**Exit criteria:**
- `docker-compose logs tempo | grep -c LIVE_TRACES_EXCEEDED` stops increasing over 15 min.
- `curl -s http://localhost:3200/metrics | grep tempo_discarded_spans_total` — the `live_traces_exceeded` series flattens (rate→0).
- Tempo memory stays < 70% (`docker stats tempo`); if it climbs toward OOM, lower back to 15000.
**Reversible:** revert the one line, `force-recreate tempo`.
**Note:** this does NOT bound disk — `/blocks` keeps refilling at 100% ingest. Phase 0 buys time; Phase 3 is the durable fix. The existing @75%/@90% disk alarms remain the safety net.

---

### Phase 1 *(executes AFTER Phase 2 — see dependency graph)* — Re-instance to c7g.2xlarge (arm64)

**This is the highest-risk phase. The data-preservation procedure is the whole game.**

**Pre-conditions (all must be green):**
- Phase 2 complete: Tempo + Mimir flushing to S3, proven by objects present in the buckets AND a kill-and-restart-Tempo-then-query test (object presence alone does not prove readability — see §8).
- All five images expose arm64 (already verified §0; re-confirm at execution): `for i in grafana/tempo:2.6.1 grafana/loki:3.3.2 grafana/mimir:2.14.1 grafana/grafana:12.3.0 otel/opentelemetry-collector-contrib:0.142.0; do docker manifest inspect $i | grep -q arm64 && echo "$i OK" || echo "$i MISSING-ARM64-STOP"; done`.
- `aws ec2 describe-instance-types --instance-types c7g.2xlarge --region us-east-1` shows `arm64` in `SupportedArchitectures` and `us-east-1a` in `AvailabilityZones`.
- **`user_data.tpl` buildx arch fix applied (§4.9)** — without it grafana-init fails to build on arm64 and the bring-up aborts.
- **Grafana state exported (§ below)** — `grafana-data` is DESTROYED by the replace and is NOT on S3.

**⚠️ DATA-LOSS SCOPE OF THE REPLACE (read before approving).** The cross-arch replace gives the new instance a fresh root volume. What survives vs. is lost:
| Volume | On S3 after Phase 2? | Survives re-instance? |
|---|---|---|
| `tempo-data` (trace blocks) | ✅ yes | ✅ committed blocks (only in-flight WAL lost) |
| `mimir-data` (metric blocks) | ✅ yes | ✅ committed blocks (only in-flight TSDB head lost) |
| **`loki-data` (logs)** | ❌ no (Loki S3 deferred) | ❌ **ALL LOGS LOST** — accepted (28KB today) but state it |
| **`grafana-data`** | ❌ no | ❌ **LOST**: UI-created dashboards, API keys, service-account tokens, UI alert rules, annotations. Provisioned datasources (file-based, in git) DO survive. |

**Pre-cutover Grafana export (mandatory if any UI-created dashboards/alerts/keys exist):**
```bash
# From a machine with Grafana admin creds (replace TOKEN):
for uid in $(curl -s -H "Authorization: Bearer $TOKEN" https://grafana.example.com/api/search?type=dash-db | jq -r '.[].uid'); do
  curl -s -H "Authorization: Bearer $TOKEN" "https://grafana.example.com/api/dashboards/uid/$uid" > "dash-$uid.json"
done
# Re-import after Phase 1, or move dashboards to file-based provisioning (preferred — survives all future re-instances).
```
Best practice going forward: move dashboards + alert rules to **file-based provisioning** under `config/grafana/provisioning/` (in git) so they're immune to volume loss.

**Step 1 — Belt-and-suspenders snapshot (even though S3 holds committed blocks):**
```bash
aws ec2 create-snapshot --volume-id vol-0123456789abcdef0 \
  --description "pre-c7g-reinstance $(date -u +%FT%TZ)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=lgtm-pre-c7g}]'
# Wait for state=completed before proceeding.
```

**Step 2 — Make the instance replacement non-destructive of *future* applies and explicit about *this* one.**
Edit `main.tf` (see §4) to: (a) flip the AMI arch filter to `arm64`, (b) **pin the AMI** so future unrelated applies don't silently re-replace the instance, and (c) add `root_block_device.delete_on_termination = false` so the old volume is *retained* (not auto-deleted) when the instance is replaced — giving an extra recovery handle.

**Step 3 — Update Secrets Manager** `/example/dev/lgtm-stack`: `instance_type` `t3a.xlarge → c7g.2xlarge`.

**Step 4 — `terraform plan` and READ IT.** Expect exactly: `aws_instance.lgtm_instance` **must be replaced** (because `ami` changed — ForceNew), Route53 A records update to the new IP. Confirm no *other* resource is being destroyed. This REPLACE is intended and is why Phase 2 (S3) and Step 1 (snapshot) come first.

**Step 5 — `terraform apply`.** New arm64 c7g instance boots, `user_data.tpl` runs (with the corrected buildx arch map — see §4), clones the repo, `docker-compose up`. Tempo/Mimir come up pointing at S3 and **re-discover the committed blocks** (no data loss for flushed telemetry; only in-flight WAL/TSDB from the cutover instant is lost).

**Step 6 — Capture the latency baseline** on the new box (per locked sequencing) for 24-48h BEFORE tuning sampling thresholds: record p50/p95/p99 of a representative trace, `docker stats` CPU per container, and `df -h /`.

**Exit criteria:**
- `uname -m` = `aarch64`; all containers `Up`, `docker images` show arm64 digests; `grafana-init` exited 0 (users provisioned — gated on buildx working).
- Tempo `/api/search/tags` returns data sourced from S3; Grafana Explore queries old (pre-reinstance) traces successfully.
- **CPUUtilization sustained < 70%** on the 8-vCPU box (do NOT look for `CPUCreditBalance` — c7g is fixed-performance and emits no credit metric; checking it would mislead you into thinking monitoring is broken).
- Disk flat (S3-backed); only WAL/TSDB on EBS.

**Rollback:** revert `instance_type` to `t3a.xlarge` in Secrets Manager AND the AMI filter to `x86_64` in `main.tf` (re-pin to the last known-good x86 AL2023 AMI), `terraform apply`. This is again a REPLACE, but the pre-cutover EBS snapshot + S3 blocks make it safe. If the new instance never came healthy, the retained old volume (Step 2c) can be reattached. **Never `terraform destroy`** during rollback (it deletes everything).

---

### Phase 2 *(executes FIRST after Phase 0)* — S3 backends for Tempo + Mimir

**Goal:** move committed trace/metric blocks off EBS to S3 so (a) disk stops being the constraint and (b) re-instance becomes safe. Same architecture, no re-instance — fully reversible.

**Step 1 — Provision infra (`main.tf`, see §4):** two buckets (NO versioning — these are ephemeral block stores; versioning weakens the lifecycle backstop because `expiration` on a versioned bucket only creates delete markers), lifecycle expiration (4d traces / 15d metrics), free S3 Gateway VPC Endpoint associated with the public route table, scoped IAM `aws_iam_role_policy` on `lgtm-ec2-instance-role`, CloudTrail S3 data events on the two buckets feeding a metric-filter alarm (the silent-IAM-failure detector — NOT S3 server access logs, which are latent and don't reliably record 403s).

**Step 2 — Pre-flight from the instance (gates the cutover):**
```bash
echo test | aws s3 cp - s3://<actual-traces-bucket>/preflight.txt && \
aws s3 rm s3://<actual-traces-bucket>/preflight.txt && echo "TRACES OK"
echo test | aws s3 cp - s3://<actual-metrics-bucket>/preflight.txt && \
aws s3 rm s3://<actual-metrics-bucket>/preflight.txt && echo "METRICS OK"
# Confirm traffic uses the gateway endpoint (no IGW egress):
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[?ServiceName==`com.amazonaws.us-east-1.s3`].RouteTableIds'
```
If either `cp` fails, STOP — fix IAM/bucket-name before touching configs.

**Step 3 — Flip backends** (`config/tempo-config.yaml`, `config/mimir-config.yaml`, see §4 for exact corrected keys), `docker-compose up -d --force-recreate tempo mimir`.

**Exit criteria:**
- `aws s3 ls s3://<traces-bucket>/<tempo-prefix>/` and `.../<metrics-prefix>/` show objects appearing within ~15 min (after first block flush).
- `docker-compose logs tempo | grep -i s3` and `... mimir | grep -i s3` show successful backend init, no auth errors.
- EBS `tempo-data`/`mimir-data` `_data` dirs stop growing (only WAL/TSDB remain local).
- CloudTrail-backed alarm in `OK` (PutObject succeeding).

**Reversible:** revert the two configs to `backend: local`/`filesystem`, `force-recreate`. New writes go local again; S3 objects age out via lifecycle.

---

### Phase 3 — Tail-sampling + generator-on-full-stream

**Goal:** bound stored-trace volume without biasing metrics. **The topology is the deliverable** (see §5). Applied on the c7g box, thresholds tuned against the Phase-1 baseline.

**Change (`config/otel-collector-config.yaml`, see §4):** split the traces pipeline so the **full 100% stream** reaches both (a) the Tempo generator path (for span-metrics/service-graphs/local-blocks) and (b) the `tail_sampling` processor whose output is the **only** thing written to Tempo's *storage* path. Concretely for a single in-process collector: keep Tempo's metrics_generator fed by 100% by sending the **unsampled** stream to Tempo's distributor for generation, and constrain stored blocks via sampling/retention — implemented here by exporting the full stream to the generator and the sampled stream to storage through Tempo's two ingest paths is not natively separable in 2.6.1, so we use the collector-connector form:

- `traces/in` (otlp) → `[memory_limiter, batch]` → **fans out** to:
  - `spanmetrics` + `servicegraph` **connectors** (compute RED + service graph on the FULL stream; `routing_key` is irrelevant because connectors run *before* sampling) → `metrics/gen` pipeline → `prometheusremotewrite/mimir`.
  - `traces/store` pipeline: `[tail_sampling]` → `otlphttp/tempo` (stored blocks only).
- **DISABLE** `span-metrics` and `service-graphs` in Tempo's `metrics_generator` to avoid double-counting on the now-sampled stored stream. Keep Tempo `local_blocks` (B3 TraceQL-metrics) — and document that TraceQL-metrics reflect the **stored (sampled)** view (known, bounded caveat), OR keep local_blocks fed by a full-stream exporter if full-fidelity TraceQL-metrics is required.

`tail_sampling` policies: `status_code: [ERROR]` **only** (NOT `[ERROR, UNSET]` — UNSET is the default on nearly every span, which would keep ~100% and defeat sampling), `latency >= 500ms`, `string_attribute db.system` present (use `enabled_regex_matching` or enumerate against actually-instrumented backends), `probabilistic 5%` baseline. Set `decision_wait: 10s` **explicitly** (default is 30s = 3× the memory/backpressure of the modeled 10s) and `num_traces` sized to measured peak concurrency (start 100000, watch tail-sampler internal metrics).

**Exit criteria (TWO-part fidelity gate — B4 fix):**
- **(a) Metrics unbiased:** `rate(traces_spanmetrics_calls_total[5m])` (from the connectors) is **unchanged** across the sampling cutover (1h before vs after). Necessary but NOT sufficient — the connector emits the same series whether or not storage works, so this alone cannot tell "correct" from "storage silently broken."
- **(b) Storage IS sampled:** stored-trace ingest (`rate(tempo_distributor_spans_received_total[5m])` on the Tempo distributor, or block-write rate) **drops to ≈ the sample fraction** while (a) holds flat. The PAIR is the real gate: connector-rate flat AND stored-rate down ⇒ metrics full-fidelity + traces correctly sampled. If (a) drops, metrics are wrongly downstream of the sampler. If (b) does NOT drop, sampling isn't taking effect.
- **Apply atomically:** restart collector AND Tempo together when switching generator→connector span-metrics, else a transient gap (no metrics) or double-count (conflicting `source` labels → counter-reset `rate()` corruption) appears. Verify no double `traces_spanmetrics_calls_total` series by `source`/`job` after cutover.
- Stored-trace disk growth drops sharply (target < 200MB/day vs ~7GB/day at 100%), validated 48h.
- Error/slow/DB traces are 100% present: `curl 'http://localhost:3200/api/search?tags=status%3DERROR&limit=10'` returns recent error traces.
- Collector CPU drops (fewer spans exported to storage); zpages (if enabled) show non-zero accept/drop counters per policy.

**Reversible:** remove `tail_sampling` + connectors, re-enable Tempo generator span-metrics/service-graphs, restore `traces: [memory_limiter, batch] → otlphttp/tempo`, `force-recreate otel-collector tempo`.

---

### Phase 4 — Correlation features C1-C5

**Goal:** all five correlation features functional and provisioned. File-based (survives re-instance).
**Changes:** `config/grafana/provisioning/datasources/datasources.yaml` (full rewrite, §4) — modernize to `tracesToLogsV2`, add `tracesToMetrics` with sanitized label values, `nodeGraph.enabled`, verify `derivedFields`, `exemplarTraceIdDestinations`. **Plus a Mimir config change** (`limits.max_global_exemplars_per_user: 100000`) because Mimir stores **zero** exemplars by default — without it C4 is dead regardless of datasource config.
**Exit criteria (each verified against the demo tenant):**
- C1 trace→logs: span "Logs for this span" jumps to Loki filtered by the trace (verify the Loki label is actually `service_name`, the OTLP default, not `service`).
- C2 logs→trace: `TraceID` derived field in Loki opens the Tempo trace.
- C3 trace→metrics: span detail shows the RED queries and they return data.
- C4 exemplars: `curl -H 'X-Scope-OrgID: demo' http://localhost:9009/prometheus/api/v1/query_exemplars --data-urlencode 'query=traces_spanmetrics_latency_bucket' --data-urlencode 'start=...' --data-urlencode 'end=...'` returns non-empty AFTER exemplar storage is enabled; clicked exemplar resolves to a STORED trace (attach exemplars to kept classes).
- C5 service map + node graph render (service map needs `traces_service_graph_request_total` non-zero; node graph is per-trace and needs no generator metrics).
**Reversible:** `git checkout` the datasources file + revert the Mimir limit, `force-recreate grafana mimir`.

---

### Phase 5 — Alerting + recording rules + self-health + dead-man's-switch

**Goal:** D3/D4 plus meta-alerting on the stack itself. Additive; low rollback risk.
**Changes:** new rule files placed at the **tenant-namespaced** ruler paths (the single-mount-at-`/etc/...` form loads ZERO rules), Mimir embedded Alertmanager actually enabled + given a tenant config, real metric names, a CloudWatch datasource (or keep CloudWatch-side alarms), corrected SNS routing, and a **functioning** dead-man's-switch on a metric the CW agent actually emits. See §4 for the exact corrected forms. Exit criteria and the long list of reviewer-corrected pitfalls are in §4 and §8.

---

## 4. Exact file changes (version-correct, copy-pasteable)

### 4.1 `config/tempo-config.yaml`

**Phase 0** — raise the cap (line 76):
```yaml
    local_blocks:
      max_live_traces: 25000          # Phase 0 bleed-stop (was 10000). Memory headroom verified (~30% used).
```

**Phase 2** — S3 backend. Replace the `storage.trace` block (lines 36-45). Note the corrected keys: WAL path is `storage.trace.wal.path` (NOT a `local:` block; `local` is the local-backend scratch dir and is inert/misleading under `backend: s3`). `endpoint` is **host-only, no scheme**. There is **no** `wal.checkpoint_duration` key in 2.6.1 — do not add it.
```yaml
storage:
  trace:
    backend: s3
    s3:
      bucket: <ACTUAL-TRACES-BUCKET>          # MUST match the provisioned name (see 4.5)
      endpoint: s3.us-east-1.amazonaws.com    # host only — NO https:// prefix
      region: us-east-1
      prefix: tempo-blocks
      insecure: false                         # credentials auto-discovered from EC2 IAM instance profile
    wal:
      path: /var/tempo/wal                    # local WAL stays on EBS (correct key)
    # (no `local:` block under backend: s3 — it would be dead/misleading config)
```

**Phase 3** — disable generator span-metrics/service-graphs (moved to collector connectors, §5) but keep `local_blocks`. Migrate the deprecated flat `overrides` to the **scoped** 2.6.1 format. Replace lines 64-99:
```yaml
  processor:
    # service_graphs and span_metrics intentionally REMOVED here — computed in the
    # collector on the FULL pre-sample stream (see §5). Tempo generator keeps ONLY local_blocks.
    local_blocks:
      max_live_traces: 25000
      max_block_duration: 5m
      max_block_bytes: 500000000
      flush_check_period: 5s
      trace_idle_period: 5s
      complete_block_timeout: 15m
      flush_to_storage: true
      # trace_live_period: NOT available in Tempo 2.6.1 (requires 2.9+) — do not add.

# --- Overrides (scoped format; the flat form is deprecated, removed in Tempo 3.0) ---
overrides:
  defaults:
    global:
      max_bytes_per_trace: 20000000           # 20MB
    metrics_generator:
      processors:
        - local-blocks                        # span-metrics/service-graphs now in collector
```
> If full-fidelity TraceQL-metrics (not just RED) is required, keep `local_blocks` fed by 100% by leaving Tempo receiving the unsampled stream for generation only; the simplest correct topology is in §5.

### 4.2 `config/mimir-config.yaml`

**Phase 2** — S3 backend. Corrected keys vs the design: the YAML key is **`bucket_name`** (flag `-blocks-storage.s3.bucket-name`), **NOT `bucket`** (that is Tempo's key); the prefix is **`storage_prefix`** one level up, **NOT** `prefix` inside the s3 block; `endpoint` is host-only. Replace `blocks_storage` (lines 16-22) and add ruler/alertmanager storage:
```yaml
blocks_storage:
  backend: s3
  storage_prefix: mimir-blocks               # one level up — NOT inside s3:
  s3:
    bucket_name: <ACTUAL-METRICS-BUCKET>     # bucket_name, not bucket
    endpoint: s3.us-east-1.amazonaws.com     # host only
    region: us-east-1
    insecure: false
  tsdb:
    dir: /tmp/mimir/tsdb
    retention_period: 336h                   # local WAL/head stays on EBS

ruler_storage:
  backend: s3
  storage_prefix: mimir-ruler
  s3:
    bucket_name: <ACTUAL-METRICS-BUCKET>
    endpoint: s3.us-east-1.amazonaws.com
    region: us-east-1
    insecure: false

alertmanager_storage:
  backend: s3
  storage_prefix: mimir-alertmanager
  s3:
    bucket_name: <ACTUAL-METRICS-BUCKET>
    endpoint: s3.us-east-1.amazonaws.com
    region: us-east-1
    insecure: false
```
Remove the `common.storage` filesystem block (lines 10-14) — every consumer is overridden to s3, so it is dead config (it is **not** an "index cache").

**Phase 4** — enable exemplar storage (Mimir default is **0 = disabled**; without this C4 never works). Add to `limits` (after line 44):
```yaml
limits:
  ingestion_rate: 10000
  ingestion_burst_size: 20000
  max_label_names_per_series: 20
  max_label_value_length: 512
  max_label_name_length: 256
  max_global_exemplars_per_user: 100000      # REQUIRED for C4/D2 exemplars
```

**Phase 5** — enable the embedded Alertmanager (needed if Loki/Mimir rulers fire to it). The `-target=all` in `docker-compose.yml` does NOT include `alertmanager`; change to `-target=all,alertmanager` (see 4.7) AND provide a tenant Alertmanager config (uploaded via API or fallback config) — an enabled-but-unconfigured AM drops alerts silently. The ruler reads tenant-namespaced rules from `ruler_storage` (the `demo` tenant), not from `rule_path` (that is only the eval working dir).

### 4.3 `config/loki-config.yaml`

**Phase 5** — point the ruler at a real Alertmanager (currently `alertmanager_url: ''`, line 103) and place rules under the single-tenant `fake` namespace dir:
```yaml
ruler:
  alertmanager_url: http://mimir:9009/alertmanager   # only valid once Mimir AM is enabled (4.2/4.7)
  ring:
    kvstore:
      store: inmemory
  rule_path: /tmp/loki/rules-temp
  storage:
    type: local
    local:
      directory: /tmp/loki/rules        # rule FILES go at /tmp/loki/rules/fake/<group>.yaml (tenant=fake)
  enable_api: true
```
Loki S3 is **deferred** (loki-data is 28KB). When done later: add a NEW `schema_config` period with a future `from:` date and `object_store: s3`, keeping the existing filesystem period so pre-cutover logs stay queryable. Low priority — noted, not built here.

### 4.4 `config/otel-collector-config.yaml`

**Phase 3** — full pipeline rewrite for the split topology (§5). Key corrections folded in: NO `service.telemetry.metrics.address` (removed/hard-error in ≥0.128.0 — use the `readers` form), `status_codes: [ERROR]` only, explicit `decision_wait: 10s`, explicit `num_traces`, `sending_queue` on the Tempo exporter, optional `zpages`.
```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679        # live tail_sampling decision debugging (lock down post-tuning)

receivers:
  otlp:
    protocols:
      grpc: { endpoint: 0.0.0.0:4317 }
      http: { endpoint: 0.0.0.0:4318 }

connectors:
  forward: {}                       # fans the full stream from traces/in into traces/store (B3 fix)
  spanmetrics:                      # RED metrics on the FULL pre-sample stream
    histogram:
      explicit:
        buckets: [1ms,2ms,4ms,8ms,16ms,32ms,64ms,128ms,256ms,512ms,1s,2s,4s,8s,16s]
    dimensions:
      - { name: service.namespace }
      - { name: http.method }
      - { name: http.status_code }
  servicegraph:
    store: { ttl: 2s, max_items: 10000 }

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25
  batch:
    send_batch_size: 1024
    timeout: 1s
  tail_sampling:
    decision_wait: 10s             # explicit — default is 30s (3x memory/backpressure)
    num_traces: 100000             # size to measured peak concurrency; watch sampler internal metrics
    policies:
      - name: errors
        type: status_code
        status_code: { status_codes: [ERROR] }     # ERROR only — NOT UNSET
      - name: slow
        type: latency
        latency: { threshold_ms: 500 }
      - name: db
        type: string_attribute
        string_attribute: { key: db.system, values: [.*], enabled_regex_matching: true }
      - name: baseline
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }

exporters:
  otlphttp/tempo:
    endpoint: http://tempo:14318
    tls: { insecure: true }
    retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
    sending_queue: { enabled: true, queue_size: 5000, num_consumers: 10 }
  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    tls: { insecure: true }
    retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }
  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers: { X-Scope-OrgID: "demo" }
    retry_on_failure: { enabled: true, initial_interval: 5s, max_interval: 30s, max_elapsed_time: 300s }

service:
  extensions: [health_check, zpages]
  telemetry:
    logs: { level: info }
    metrics:                       # 0.142.0 form — `address:` is invalid/hard-error now
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
                without_type_suffix: true
                without_units: true
  pipelines:
    traces/in:                     # full 100% stream in
      receivers: [otlp]
      processors: [memory_limiter, batch]
      # connectors (spanmetrics/servicegraph) get 100%; `forward` carries 100% to the sampling pipeline.
      # tail_sampling is a PROCESSOR — it CANNOT appear in receivers:/exporters:. Use `forward` to bridge.
      exporters: [spanmetrics, servicegraph, forward]
    traces/store:                  # tail_sampling runs HERE as a processor; only kept traces are stored
      receivers: [forward]
      processors: [tail_sampling, batch]
      exporters: [otlphttp/tempo]
    metrics/gen:                   # connector output (full-fidelity RED + service graph) -> Mimir
      receivers: [spanmetrics, servicegraph]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite/mimir]
    metrics:                       # app metrics passthrough (unchanged)
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite/mimir]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/loki]
```
> **Topology note (B3 fix):** `tail_sampling` is a **processor**, not a connector — it must NOT appear in `receivers:`/`exporters:` (the collector fails config validation at boot if it does). The `forward` connector bridges `traces/in` → `traces/store`, where `tail_sampling` runs as a processor. Invariant: **`spanmetrics`/`servicegraph` connectors see 100% of spans (computed before any sampling); only the post-`tail_sampling` stream is written to Tempo storage.** Validate with `docker run --rm -v $PWD/config/otel-collector-config.yaml:/c.yaml otel/opentelemetry-collector-contrib:0.142.0 validate --config=/c.yaml` before `force-recreate`.

### 4.9 `user_data.tpl` (REQUIRED for the ARM move — H5)

`user_data.tpl:30` hardcodes `buildx-$BUILDX_VERSION.linux-amd64`. On arm64 this pulls an x86 buildx → `docker buildx` fails → `grafana-init`'s local `build:` (docker-compose.yml:178) fails → bring-up aborts → no users/teams. Fix the arch (line 30); line 18's docker-compose download is already arch-safe (`$(uname -m)` ships an `aarch64` asset, so leave it):
```bash
# Replace the hardcoded linux-amd64 with a GOARCH-mapped value:
ARCH=$(uname -m); case "$ARCH" in aarch64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; esac
sudo curl -SL "https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION.linux-$ARCH" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
```
> buildx release assets use Go arch names (`arm64`/`amd64`), NOT `uname -m` (`aarch64`/`x86_64`) — hence the map. This edit is a HARD GATE for Phase 1; it was missing from the original change list.

### 4.5 `main.tf`

**Phase 1 — AMI arch flip + PIN + retain-on-replace.** Replace lines 208-211 and the `root_block_device` block:
```hcl
  filter {
    name   = "architecture"
    values = ["arm64"]              # was ["x86_64"]
  }
```
Pin the AMI so neither this nor any *future* `terraform apply` silently force-replaces the instance (add `lifecycle` to `aws_instance.lgtm_instance`, and set retain-on-replace):
```hcl
  root_block_device {
    volume_size           = 150
    volume_type           = "gp3"
    delete_on_termination = false   # retain old root volume across the REPLACE (recovery handle)
  }

  lifecycle {
    ignore_changes = [ami]          # pin: future applies won't re-resolve a newer arm64 AMI and replace
  }
```
> Set `ignore_changes=[ami]` AFTER the first arm64 apply has resolved the new AMI, or pin `data.aws_ami` with `most_recent=false` + an exact name, so the arm64 image is selected exactly once and then frozen.

**Phase 2 — S3 + endpoint + IAM + silent-failure detection.** Use the **literal region** (there is no verified `local.secrets.region`; the provider region is hardcoded `us-east-1` at line 11). No bucket versioning. Append:
```hcl
data "aws_caller_identity" "current" {}
locals { region = "us-east-1" }

resource "aws_s3_bucket" "lgtm_traces" {
  bucket = "lgtm-traces-${local.region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-traces", Component = "Tempo", ManagedBy = "terraform" }
}
resource "aws_s3_bucket" "lgtm_metrics" {
  bucket = "lgtm-metrics-${local.region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-metrics", Component = "Mimir", ManagedBy = "terraform" }
}

# Lifecycle expiration = compactor-stall backstop. No versioning (would only create delete markers).
resource "aws_s3_bucket_lifecycle_configuration" "lgtm_traces" {
  bucket = aws_s3_bucket.lgtm_traces.id
  rule {
    id     = "expire-traces"
    status = "Enabled"
    filter {}
    expiration { days = 4 }   # 72h block_retention + compaction window + buffer
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "lgtm_metrics" {
  bucket = aws_s3_bucket.lgtm_metrics.id
  rule {
    id     = "expire-metrics"
    status = "Enabled"
    filter {}
    expiration { days = 15 }  # 336h tsdb retention + buffer
  }
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = data.aws_vpc.target_vpc.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_route_table.public.id]
  tags              = { Name = "lgtm-s3-gateway", ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "lgtm_s3_access" {
  name = "lgtm-s3-access"
  role = aws_iam_role.lgtm_instance_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Traces", Effect = "Allow",
        Action = ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
        Resource = [aws_s3_bucket.lgtm_traces.arn, "${aws_s3_bucket.lgtm_traces.arn}/*"] },
      { Sid = "Metrics", Effect = "Allow",
        Action = ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket"],
        Resource = [aws_s3_bucket.lgtm_metrics.arn, "${aws_s3_bucket.lgtm_metrics.arn}/*"] }
    ]
  })
}
```
> The Tempo `bucket:`/Mimir `bucket_name:` config values MUST equal these provisioned names — the names contain the account id, so fill them in after `terraform apply` outputs them. Mismatch = the exact silent-write failure the backstop guards against.

**Phase 5 — SNS publish + working dead-man's-switch.** The CW agent (per `config/cloudwatch-agent-config.json`) emits `cpu_*`, `mem_*`, `disk_*`, etc. — there is NO `CountOfMetricsPublished` or `aws_lgtm_heartbeat` metric. Build the dead-man's-switch on a metric that is actually published, with `treat_missing_data = "breaching"`:
```hcl
resource "aws_iam_role_policy" "lgtm_sns_publish" {
  name = "lgtm-sns-publish"
  role = aws_iam_role.lgtm_instance_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sns:Publish"],
      Resource = "arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:lgtm-stack-alerts" }]
  })
}

resource "aws_cloudwatch_metric_alarm" "lgtm_deadmans_switch" {
  alarm_name          = "lgtm-deadmans-switch"
  namespace           = "LGTM/EC2"
  metric_name         = "mem_used_percent"       # real, emitted every 60s by the CW agent
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 0                          # value can't be <0; only fires on MISSING data
  treat_missing_data  = "breaching"                # THIS is what makes it a dead-man's switch
  alarm_description   = "No LGTM/EC2 metrics in 5m → host down / CW agent dead / network partition."
  alarm_actions       = ["arn:aws:sns:us-east-1:${data.aws_caller_identity.current.account_id}:lgtm-stack-alerts"]
  tags                = { Name = "lgtm-deadmans-switch", Component = "observability" }
}
```

### 4.6 `config/grafana/provisioning/datasources/datasources.yaml`

**Phase 4** — full rewrite. Corrections: `tracesToLogsV2` (V1 `tracesToLogs` is deprecated on 12.3.0 — the "only ≥5.0" claim is false); `tracesToMetrics` tag **values sanitized** (`http.method`→`http_method`, `http.status_code`→`http_status_code`; Tempo writes dotted attrs as underscored Prometheus labels, and dotted label keys are invalid PromQL); Loki UID is **`Loki`** (capital L); Mimir URL keeps `/prometheus` and the `X-Scope-OrgID: demo` header; `nodeGraph` is its own block (per-trace, no generator dependency).
```yaml
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    uid: Loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: '(?:traceID|trace_id|traceId)=(\w+)'
          name: TraceID
          url: '$${__value.raw}'
    isDefault: false

  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      httpMethod: GET
      tracesToLogsV2:
        datasourceUid: Loki
        spanStartTimeShift: '-1h'
        spanEndTimeShift: '1h'
        filterByTraceID: true
        filterBySpanID: false
        tags:
          - { key: 'service.name', value: 'service_name' }   # OTLP default Loki label is service_name
          - { key: 'job' }
      tracesToMetrics:
        datasourceUid: Mimir-Prometheus
        spanStartTimeShift: '-2m'
        spanEndTimeShift: '2m'
        tags:
          - { key: 'service.name', value: 'service' }          # spanmetrics dimService label = service
          - { key: 'http.method', value: 'http_method' }       # sanitized
          - { key: 'http.status_code', value: 'http_status_code' }
        queries:
          - { name: 'Request rate',  query: 'rate(traces_spanmetrics_calls_total{$${__tags}}[5m])' }
          - { name: 'Error rate',    query: 'rate(traces_spanmetrics_calls_total{status_code="STATUS_CODE_ERROR",$${__tags}}[5m])' }
          - { name: 'p95 latency',   query: 'histogram_quantile(0.95, sum(rate(traces_spanmetrics_latency_bucket{$${__tags}}[5m])) by (le))' }
      serviceMap:
        datasourceUid: Mimir-Prometheus
      nodeGraph:
        enabled: true
      search:
        hide: false
    isDefault: false

  - name: Mimir-Prometheus
    type: prometheus
    uid: Mimir-Prometheus
    access: proxy
    url: http://mimir:9009/prometheus
    jsonData:
      httpMethod: POST
      httpHeaderName1: 'X-Scope-OrgID'
      exemplarTraceIdDestinations:
        - name: trace_id           # VERIFY against query_exemplars output; Tempo often emits 'traceID'
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: 'demo'
    isDefault: true
```

### 4.7 `docker-compose.yml`

**Phase 1** — if the collector arm64 gate forces a different image/tag, change `otel-collector.image` (line 154). Otherwise no change for the arch move (other images pull arm64 manifests automatically; `grafana-init` builds locally and depends on the corrected buildx).

**Phase 3** — expose collector debug/metrics ports (lock down after tuning). Under `otel-collector.ports` (lines 159-161) add `"55679:55679"` and `"8888:8888"`.

**Phase 5** — enable Mimir embedded Alertmanager and mount rule files at tenant-namespaced paths:
```yaml
  mimir:
    command: -target=all,alertmanager -config.file=/etc/mimir/config.yaml   # add ,alertmanager
    volumes:
      - ./config/mimir-config.yaml:/etc/mimir/config.yaml
      - ./config/rules/mimir/demo:/tmp/mimir/ruler-storage/demo:ro           # tenant=demo
      - mimir-data:/tmp/mimir
  loki:
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml
      - ./config/rules/loki/fake:/tmp/loki/rules/fake:ro                     # tenant=fake (auth disabled)
      - loki-data:/tmp/loki
```

### 4.8 New rule files (Phase 5)

- `config/rules/mimir/demo/recording.yaml` — recording rules computed on the **real** emitted metrics (`traces_spanmetrics_calls_total`, `traces_spanmetrics_latency_bucket`, `traces_service_graph_request_total`) — NOT `http_requests_total`/`http_request_duration_seconds_bucket`, which this stack does not emit. Verify names: `curl -H 'X-Scope-OrgID: demo' http://localhost:9009/prometheus/api/v1/label/__name__/values | grep traces_`.
- `config/rules/mimir/demo/alerts.yaml` — stack-health alerts on **verified 2.6.1 metric names**: `tempo_discarded_spans_total{reason="live_traces_exceeded"}` (rate > 0), `tempo_metrics_generator_processor_local_blocks_live_traces` (saturation), `tempodb_compaction_outstanding_blocks` (compactor stall) — NOT the invented `tempo_metrics_generator_active_traces` / `tempo_compactor_queue_length` / `tempo_metrics_generator_metrics_exported`. Span-discard alert `for: 30m` (or silence-keyed) so the unresolvable-until-Phase-3 critical doesn't mask new signals.
- `config/rules/loki/fake/alerts.yaml` — LogQL alerts; case-insensitive `|~ "(?i)error"`; valid RE2 only.
- Mimir Alertmanager tenant config (uploaded via `mimirtool alertmanager load --id demo <file>` or a fallback config) with an SNS receiver (AM natively supports `sns_configs` via the instance role) — OR route everything through Grafana unified alerting via a **webhook** contact point (Grafana 12.3.0 has **no native `sns` contact-point type** — the `type: sns` form is invalid). Pick ONE delivery path.

Stack-health rules that reference `{job="mimir"}` / `{service="tempo"}` etc. require a scrape path for the components' own `/metrics`; until one exists (Prometheus scrape or a collector `prometheus` receiver), rely on CloudWatch host metrics + the Tempo `/metrics` discard counter, not on self-scraped Go runtime metrics.

---

## 5. The sampling-vs-metrics resolution (definitive)

**Problem.** `tail_sampling` keys by `traceID`; `spanmetrics` aggregates by `service`. If you sample first and generate second, RED/service-graph/TraceQL metrics are computed on the surviving ~5% and are understated by the drop fraction. The original designs put `tail_sampling` *inside* the collector *upstream* of Tempo, which means Tempo's generator (fed from the distributor) only ever sees the sampled stream — silently biasing every RED panel and the service map. Both reviewers flagged this as the headline fidelity bug.

**Resolution — generate before sampling, store after.** Compute metrics in the **collector** with the `spanmetrics` + `servicegraph` **connectors**, which run on the **full 100% pre-sample stream** (the fan-out from `traces/in`). The `routing_key` conflict disappears because connectors execute *before* any sampling decision — a single in-process collector aggregates by service over the complete stream, which is exactly correct. The `tail_sampling` processor forks a separate `traces/store` pipeline whose output is the **only** thing written to Tempo's trace storage. Tempo's own `metrics_generator` is reduced to `local-blocks` only (span-metrics/service-graphs disabled there to avoid double-counting on the sampled stored stream).

**Consequences, stated honestly:**
- **B1 span/RED metrics, B2 service graphs, C3 trace→metrics, C5 service map: 100% accurate** — from the connectors, full stream.
- **C4 exemplars:** emitted by the connectors and attached to full-stream metrics; to avoid dead exemplars (trace-not-found on click), attach exemplars preferentially to **kept** classes (errors/slow/DB), which are stored at 100%. Probabilistically-sampled traces may still 404 on exemplar click — documented, bounded.
- **B3 TraceQL-metrics (Tempo `local_blocks`):** as configured, `local_blocks` is fed by the stored (sampled) stream, so TraceQL-metrics reflect the sampled view. If full-fidelity TraceQL-metrics is required, feed Tempo's distributor the unsampled stream for generation only (a second `otlphttp/tempo`-to-distributor exporter on `traces/in`) and keep storage sampled — at the cost of more Tempo CPU. Default plan accepts the bounded TraceQL-metrics caveat; flag in §9 for the team to decide.
- **The fidelity gate (Phase 3 exit):** `rate(traces_spanmetrics_calls_total[5m])` must be **unchanged** before vs after enabling sampling. If it drops, the topology is wrong (metrics are downstream of the sampler) — do not ship.

---

## 6. Cost (corrected)

| Item | Today (t3a.xlarge, EBS) | Target (c7g.2xlarge, S3) |
|---|---|---|
| Compute | t3a.xlarge ~$109/mo | **c7g.2xlarge ~$197/mo on-demand** / **~$124/mo w/ 1-yr Compute Savings Plan** |
| Root EBS | 150GB gp3 = $12/mo | 50GB gp3 = **$4/mo** (S3 holds blocks; EBS only WAL/TSDB/OS) |
| S3 | — | storage ~$2-3/mo + requests <$5/mo + **same-region transfer $0** (free Gateway endpoint) |
| CloudWatch alarms/CloudTrail data events | existing | +~$1-2/mo (S3 data events) |
| **Total** | **~$121/mo** (baseline) | **~$210/mo on-demand** / **~$140/mo with Savings Plan** |

c7g.2xlarge (8 vCPU) is ~2× the 4-vCPU baseline, directly relieving the vCPU saturation described above; it is **fixed-performance** (no burst-credit cliff). The on-demand delta (~$90/mo) buys 2× compute, fixed performance, and S3 durability; a 1-yr Compute Savings Plan brings it to roughly cost-neutral. **Open item:** confirm whether existing Savings Plans/RIs cover c7g (some x86-only plans do not).

---

## 7. Risk register

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| R1 | **Cross-arch re-instance destroys the 150GB root EBS + all named volumes** (AMI change is ForceNew; root vol `delete_on_termination` defaults true). | CRITICAL | Sequence S3 BEFORE re-instance (committed blocks survive) + pre-cutover EBS snapshot + `delete_on_termination=false` (retain old vol) + read `terraform plan` to confirm only the instance replaces. |
| R2 | **Stop/start cannot do a cross-arch move** — x86 root fs/kernel won't boot on Graviton (the design's central premise was false). | CRITICAL | Plan uses AMI-replace + S3/snapshot restore, NOT stop/start. Explicit in Phase 1. |
| R3 | ~~Collector 0.142.0 has no arm64 manifest~~ — **DISPROVEN by `docker manifest inspect` (§0): all 5 images have linux/arm64.** | RESOLVED | Cheap re-check kept in Phase 1 pre-flight as defense against a future re-pin; expected to pass. No image blocker for ARM. |
| R3b | **grafana-data + loki-data destroyed by the cross-arch replace** (NOT on S3). Silent loss of UI dashboards/API keys/alerts + all logs. | HIGH | Mandatory pre-cutover Grafana export (Phase 1); move dashboards/alerts to file-based provisioning in git; accept log loss explicitly (28KB). |
| R4 | **Future `terraform apply` silently re-replaces the instance** (`most_recent=true` AMI resolves a newer arm64 image). | HIGH | Pin AMI (`most_recent=false`+exact name) or `lifecycle{ignore_changes=[ami]}` after first arm64 apply. |
| R5 | **Silent S3 IAM write failure** — ingesters stop flushing without crashing → data loss. | HIGH | Pre-flight `aws s3 cp` from instance (gates cutover); CloudTrail S3 data-event alarm (NOT latent server access logs); alarm on `tempodb_compaction_outstanding_blocks` / Mimir upload-failure metrics; bucket-name in config must equal provisioned name. |
| R6 | **Metrics biased by sampling** (generate-after-sample). | HIGH | §5 topology: connectors on 100% stream; Phase 3 exit gate compares `traces_spanmetrics_calls_total` rate before/after. |
| R7 | **buildx wrong-arch 404 on arm64** (`linux-aarch64` asset does not exist; uname returns aarch64 but buildx uses GOARCH `arm64`). | MED | `user_data.tpl` arch map: `ARCH=$(uname -m); [ "$ARCH" = aarch64 ] && ARCH=arm64; [ "$ARCH" = x86_64 ] && ARCH=amd64; ...linux-$ARCH`. Leave docker-compose download as `$(uname -m)` (it DOES ship `aarch64`). |
| R8 | **Lifecycle backstop weakened by versioning** (delete markers, not byte-free). | MED | No bucket versioning on the ephemeral block stores. |
| R9 | **Mimir/Loki rulers load zero rules** (single-file mount, wrong tenant dir). | MED | Tenant-namespaced mounts: Mimir `…/ruler-storage/demo/`, Loki `…/rules/fake/`. |
| R10 | **Alerts dropped** — Mimir AM not enabled / no tenant config; Grafana has no native SNS. | MED | `-target=all,alertmanager` + AM tenant config with `sns_configs`, OR Grafana webhook→SNS. One path only. |
| R11 | **Dead-man's-switch never fires** (alarm on a non-existent metric). | MED | Alarm on real `mem_used_percent` with `treat_missing_data="breaching"`. |
| R12 | **Re-instance latency regression / threshold mis-tune.** | LOW | Capture 24-48h baseline on c7g BEFORE tuning sampling thresholds (locked sequencing). |
| R13 | **grafana-init never runs** (buildx broken) → no users/teams. | LOW | R7 fix + Phase-1 exit asserts `grafana-init` exited 0. |

---

## 8. Validation plan (prove full fidelity + all features + no span drops)

**Per-phase gates are the per-phase exit criteria above.** Cross-cutting fidelity proofs:

- **No ongoing span drops (Phase 0 + Phase 3):** `curl -s http://localhost:3200/metrics | grep 'tempo_discarded_spans_total{reason="live_traces_exceeded"}'` — counter flat (rate 0) after Phase 0; remains flat post-sampling.
- **Metrics are full-fidelity, not sampled (Phase 3 — THE gate):** record `rate(traces_spanmetrics_calls_total[5m])` (demo tenant, `/prometheus` path, `X-Scope-OrgID: demo`) for 1h before enabling `tail_sampling` and 1h after; **must match within noise**. A drop ≈ sample fraction proves metrics are wrongly downstream of the sampler.
- **Errors/slow/DB stored at 100%:** generate known error + >500ms + DB spans; confirm each is queryable in Tempo after `decision_wait`.
- **S3 is actually the store (Phase 2):** `aws s3 ls` shows growing object counts; EBS `_data` dirs flat; kill-and-restart Tempo, confirm old traces still queryable (proves they're in S3, not local).
- **Re-instance lost nothing committed (Phase 1):** query a trace ingested before re-instance; it resolves from S3 on the new arm64 box.
- **Correlation (Phase 4):** click through C1-C5 per the Phase-4 exit criteria; for C4, `query_exemplars` returns non-empty and a clicked exemplar opens a stored trace.
- **Alerting (Phase 5):** `mimirtool rules check`; `curl -H 'X-Scope-OrgID: demo' http://localhost:9009/prometheus/api/v1/rules` (NOT the un-headered `/api/prom/...` form) shows loaded groups; `curl http://localhost:3100/loki/api/v1/rules` non-empty; force the dead-man's-switch by stopping the CW agent and confirm the alarm transitions to ALARM and SNS delivers (confirm the email subscription first).
- **Confidence bar after any retention/storage/sampling change:** disk/series flat for **≥48h**, not just one compaction window.

---

## 9. Open items

1. **Sampling thresholds** — `latency >= 500ms` and `probabilistic 5%` are placeholders. Tune against the Phase-1 c7g latency baseline; capture real p95/p99 first, then set the slow threshold above the normal p95 and the probabilistic rate to hit the disk-growth target (< 200MB/day). `num_traces` to be sized from observed peak concurrent traces.
2. **TraceQL-metrics fidelity (B3)** — default plan lets `local_blocks` see only the sampled stored stream (TraceQL-metrics = sampled view). Decide whether full-fidelity TraceQL-metrics warrants the extra Tempo CPU of a second full-stream generation path (§5).
3. **Slack relay** — SNS `lgtm-stack-alerts` email is pending confirmation; add a Slack relay (SNS→Lambda→Slack, or Grafana webhook→Slack) once delivery path in §4.8 is chosen.
4. **SSH ingress lockdown** — SG `sg-0123456789abcdef0` port 22 is `0.0.0.0/0` (HIGH). Restrict to VPN/office CIDR via `ssh_ingress_cidr` in Secrets Manager (one-line SG change). Independent of all phases; do it early.
5. **Savings Plan coverage for c7g** — confirm before committing (some x86-only plans don't cover Graviton); `instance_type` in Secrets Manager allows instant fallback if needed.
6. **Loki S3** — deferred (28KB). New-schema-period approach noted in §4.3 when warranted.
7. **Component self-scrape** — stack-health Go-runtime alerts need a scrape path for Mimir/Loki/Tempo `/metrics`; add a collector `prometheus` receiver or Prometheus scrape if those alerts are wanted.
8. **Grafana admin rotation** — verify `admin/admin` (compose default) was actually rotated by `grafana-init`; on the fresh c7g box re-confirm post-Phase-1.
```
