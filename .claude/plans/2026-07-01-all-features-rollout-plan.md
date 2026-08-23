# LGTM All-Features Rollout Plan (design-verified, apply-with-approval)

**Created:** 2026-07-01 | **Status:** PLAN ONLY — 4 phases, apply each with approval. All 4 source designs were adversarially rejected+corrected (12 cross-cutting fixes). Nothing applied.

All facts verified. Key confirmations:
- IAM policy scopes `s3:*Object`/`ListBucket` to the whole bucket (`/*`), so a new `alertmanager/` or `ruler/` prefix is already covered — no IAM change needed for S3-backed rules/AM.
- The Mimir config comment claims `common.storage` auto-applies to ruler/alertmanager with distinct prefixes, but `ruler_storage` is explicitly overridden to `filesystem`, and there is NO `alertmanager_storage` block. So alertmanager currently has no store.
- CloudWatch agent `file_path: /var/log/docker` — the review's "broken log source" flaw is confirmed (that's a daemon log path assumption; the metrics `resources` also reference `/var/lib/docker`).
- No `send_exemplars` on the collector's `prometheusremotewrite/mimir` exporter → defaults to `true` in 0.142.0, confirming the review's "wrong root cause / no-op change #1" flaw.

I have everything needed. Here is the synthesized plan.

---

# LGTM All-Features Rollout — Sequenced, Apply-With-Approval Plan

All four source designs were adversarially rejected (`holds:false`). Every fatal/material flaw below is corrected, not repeated. Confidence is marked per item. `[NEEDS-VERIFY]` = assert-on-box before declaring done. Target is a single EC2 host (t3a.2xlarge class), SSM-only, `docker-compose` (hyphen).

## 0. Cross-cutting corrections applied (do not regress)

| # | Rejected claim | Correction baked into this plan |
|---|---|---|
| C1 | `tracesToMetricsV2` field | No such field. Use `tracesToMetrics` (no V2). Only `tracesToLogsV2` exists. |
| C2 | `$__tags` with dotted keys | Connector metrics carry underscore labels. Every tag needs `value:` mapping (`service.name`→`service_name`). |
| C3 | `span.kind`/`status.code` in tags | Drop from `tags` (span-attr values ≠ enum label values). Error query pins `status_code="STATUS_CODE_ERROR"` literally. |
| C4 | `traces_spanmetrics_*` metric name | Connector emits `traces_span_metrics_*` (underscore). `traces_spanmetrics_*` is the Tempo-generator series (starved / separate). Duration is `..._duration_milliseconds_bucket`, not `_latency_bucket`. |
| C5 | collector `send_exemplars: false` default | Defaults to **true** in 0.142.0. Change is a no-op; drop it as a "blocker". |
| C6 | Loki ruler evaluates stack-health rules | Loki ruler runs **LogQL over log streams**, cannot read `loki_*` operational metrics. Those are PromQL and belong in the **Mimir** ruler — and require a scrape that does not exist. |
| C7 | "Grafana 12.3.0 has no SNS" | Grafana has a **native Amazon SNS contact point** since 2024. No webhook shim needed. |
| C8 | rules at `/tmp/mimir/rules/demo/` | That's the ruler WAL/working dir. Rule source dir is `ruler_storage.filesystem.dir` = `/tmp/mimir/ruler-storage/<tenant>/`. |
| C9 | SNS topic "pre-exists" | It does **not**. No SNS/alarm/canary resources in `main.tf`/`s3-backends.tf`. Terraform must create them. |
| C10 | `nodeGraph` needs `traces_service_graph_*` | Backwards. `nodeGraph.enabled:true` renders from the trace itself (no metrics dep). `serviceMap` (already present) is what needs the graph metrics. |
| C11 | CW agent log source `/var/log/docker` | Wrong for json-file driver. Container logs live at `/var/lib/docker/containers/*/*.log`. |
| C12 | `alertmanager_storage` present | Absent. Must be added before `-target=all,alertmanager`, with a **distinct S3 prefix** or filesystem. |

---

## Phase A — Config-only correlation wins (cannot destabilize)

**Scope:** `datasources.yaml` only. Grafana re-reads on restart. Writes nothing to Mimir/Tempo/Loki; touches no ingestion path. Fully reversible via `git revert` + `docker-compose restart grafana`.
**Confidence: HIGH.**

### A. Exact change — `config/grafana/provisioning/datasources/datasources.yaml`

Replace the **Tempo** datasource `jsonData` block (lines 26–43) with:

```yaml
    jsonData:
      httpMethod: GET
      tracesToLogsV2:
        datasourceUid: Loki
        tags:
          - key: job
          - key: instance
          - key: pod
          - key: namespace
          - key: service.name
            value: service_name
        spanStartTimeShift: '-1h'
        spanEndTimeShift: '1h'
        filterByTraceID: true
        filterBySpanID: false
      tracesToMetrics:                       # C1: NOT tracesToMetricsV2
        datasourceUid: Mimir-Prometheus
        spanStartTimeShift: '-1h'
        spanEndTimeShift: '1h'
        tags:                                # C2/C3: only service.name+span.name, with underscore mapping
          - key: service.name
            value: service_name
          - key: span.name
            value: span_name
        queries:
          - name: 'Request rate (RED - Calls)'
            query: 'sum(rate(traces_span_metrics_calls_total{$$__tags}[5m])) by (service_name, span_name)'
          - name: 'Error rate (RED - Errors)'
            query: 'sum(rate(traces_span_metrics_calls_total{$$__tags, status_code="STATUS_CODE_ERROR"}[5m])) by (service_name, span_name)'
          - name: 'P99 latency (RED - Duration)'
            query: 'histogram_quantile(0.99, sum(rate(traces_span_metrics_duration_milliseconds_bucket{$$__tags}[5m])) by (le, service_name, span_name))'
      serviceMap:
        datasourceUid: Mimir-Prometheus
      nodeGraph:
        enabled: true
      search:
        hide: false
```

Notes:
- `job/instance/pod/namespace` stay key-only (they're already flat Loki labels). `service.name→service_name` gets a `value:` because it's dotted. `[NEEDS-VERIFY]` that Loki streams actually carry these labels (app logs go to CloudWatch, so tracesToLogs may return empty for most services — feature is *wired correctly* regardless).
- `serviceMap` uses `Mimir-Prometheus` and reads `traces_service_graph_*` (present today from Tempo generator; see Phase §3).

### A validation
1. Syntax: `docker run --rm -v "$PWD/config/grafana:/c:ro" mikefarah/yq '.datasources[] | select(.name=="Tempo")' /c/provisioning/datasources/datasources.yaml`
2. `docker-compose restart grafana` then `docker-compose logs grafana | grep -i "datasource\|provision"` — no errors.
3. UI: Connections → Data sources → Tempo shows no red error. Open a trace in Explore → confirm **Logs** and **Metrics** buttons appear and the RED queries return data (dev/prod traces).
4. `[NEEDS-VERIFY]` the connector series exist: `curl -H 'X-Scope-OrgID: demo' http://localhost:9009/prometheus/api/v1/label/__name__/values | grep traces_span_metrics` (run on-box via SSM).

### A rollback
`git revert` the commit → `docker-compose restart grafana`. No data-plane impact.

---

## Phase B — Exemplars (storage-enable, watch cardinality)

**Scope:** `mimir-config.yaml` only. `datasources.yaml` `exemplarTraceIdDestinations` already correct — no change.
**Confidence: MEDIUM.** Enabling storage is safe; end-to-end *visibility* is not guaranteed (see flags).

### B. Exact change — `config/mimir-config.yaml`

Under `limits:` (after line 52, `max_label_name_length: 256`):

```yaml
  max_global_exemplars_per_user: 100000   # per-TENANT ring, not per-series (C: 10k too small for
                                          # multi-dim span/service-graph cardinality). Start 100k, tune by observation.
```

**Do NOT** touch the collector — `prometheusremotewrite` already defaults `send_exemplars: true` in 0.142.0 (C5). The connector's `spanmetrics.exemplars.enabled: true` is already set.

### The sampled-out-exemplar hazard (must document, cannot fully fix in-stack)
Connectors compute exemplars on the **100% pre-sample** stream; Tempo stores only the **tail-sampled** subset. So a stored exemplar's `trace_id` may point to a trace that was sampled out — clicking it → "trace not found". This is **guaranteed for ~90% of qa** (10% kept). dev/prod are kept 100%, so their exemplars resolve.
- **Mitigation (config-only, recommended):** scope exemplar-bearing dashboard panels to dev/prod, or annotate qa panels that exemplars may dangle. No SDK change needed for *this* mitigation.
- **[FLAG — out of stack scope]** Making qa exemplars reliably resolve would require either raising qa sampling (rejects the incident-avoidance goal) or app/SDK-side exemplar shaping. Do not attempt as part of this workstream.

### Double-emit interaction (see §3): both the connector (`traces_span_metrics_*`) and the Tempo generator (`traces_spanmetrics_*`) can push exemplars once storage is on. Resolve §3 first or accept two exemplar-bearing series.

### B validation (on-box / SSM, hyphenated compose)
1. `mimir -modules -config.file=/etc/mimir/config.yaml` dry-check, then `docker-compose restart mimir`; confirm clean startup in logs.
2. Correct endpoint (C: not `.exemplar` on `/query`):
   ```
   curl -s -H 'X-Scope-OrgID: demo' http://localhost:9009/prometheus/api/v1/query_exemplars \
     --data-urlencode 'query=traces_span_metrics_duration_milliseconds_bucket' \
     --data-urlencode "start=$(date -d '-15min' +%s)" --data-urlencode "end=$(date +%s)"
   ```
   Expect non-empty after a few scrape cycles.
3. Grafana: RED duration panel shows exemplar diamonds; click → dev/prod trace opens; qa may 404 (expected).
4. Cardinality watch: `mimir_ingester_memory_series`, `cortex_ingester_active_series`, and `ingestion_rate` headroom. `[NEEDS-VERIFY]` exemplar overhead stays well under the 30k/60k limit (this is the incident guard — see Risk Register R1).

### B rollback
Remove the line → `docker-compose restart mimir`. Exemplars stop being stored (already-stored ones age out). No schema migration.

---

## Phase C — Recording + alerting rules + ruler/alertmanager + SNS delivery

**Scope:** `mimir-config.yaml`, `docker-compose.yml`, new rule files, `main.tf` (SNS). This is the highest-risk phase; ship its sub-steps in order, each independently reversible.
**Confidence: MEDIUM, with two HARD constraints.**

### HARD CONSTRAINT 1 — you cannot alert on Tempo/Mimir internals yet (C6)
`tempo_discarded_spans_total{reason="live_traces_exceeded"}` and `tempodb_compaction_outstanding_blocks` are **not ingested** — the collector has only an `otlp` receiver; nothing scrapes `/metrics`. Two of the three proposed stack-health alerts would be **silent no-ops**.
**Decision:** In Phase C, ship ONLY rules that query series that provably exist today (`traces_span_metrics_*`, `traces_service_graph_*`). Defer internal-metric alerts to Phase D-optional (adds a Prometheus scrape). Do NOT ship silent rules.

### HARD CONSTRAINT 2 — S3 prefix collisions crash Mimir (C12)
`common.storage` is shared; blocks use `storage_prefix: blocks`. Ruler and Alertmanager stores MUST use distinct prefixes or Mimir refuses to start (the exact startup-break failure mode from the incident lineage). IAM already allows the whole bucket (`/*`), so no Terraform IAM change.

### C1. Recording rules — NEW FILE `config/mimir/rules/demo/red-recording.yaml`
Mounted into the container at `/tmp/mimir/ruler-storage/demo/red-recording.yaml` (C8: the real `ruler_storage.filesystem.dir`).

```yaml
groups:
  - name: red-recording
    interval: 30s
    rules:
      - record: service:requests:rate5m
        expr: sum by (service_name) (rate(traces_span_metrics_calls_total[5m]))
      - record: service:errors:rate5m
        expr: sum by (service_name) (rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m]))
      - record: service:error_ratio:5m
        expr: |
          service:errors:rate5m
            / clamp_min(service:requests:rate5m, 1e-9)
      - record: service:latency_p99_ms:5m
        expr: histogram_quantile(0.99, sum by (le, service_name) (rate(traces_span_metrics_duration_milliseconds_bucket[5m])))
```

### C2. Alerting rules — NEW FILE `config/mimir/rules/demo/stack-alerts.yaml`
Only series that exist today. (No `tempo_discarded_spans_total` / `tempodb_*` — see HC1.)

```yaml
groups:
  - name: stack-alerts
    interval: 30s
    rules:
      - alert: HighServiceErrorRatio
        expr: service:error_ratio:5m > 0.05
        for: 5m
        labels: {severity: warning}
        annotations:
          summary: '{{ $labels.service_name }} error ratio >5% (5m)'
      - alert: SpanMetricsPipelineSilent          # meta-alert: connectors stopped emitting = pipeline dead
        expr: sum(rate(traces_span_metrics_calls_total[10m])) == 0
        for: 10m
        labels: {severity: critical}
        annotations:
          summary: 'No span metrics from otel-collector connectors for 10m (traces pipeline down)'
```

### C3. Enable ruler API + wire alertmanager storage — `config/mimir-config.yaml`
```yaml
ruler:
  rule_path: /tmp/mimir/rules          # working/WAL dir (unchanged)
  alertmanager_url: http://localhost:9009/alertmanager   # unchanged (Mimir's own AM; correct as-is)
  enable_api: true                     # ADD
  ring:
    kvstore:
      store: inmemory

alertmanager:
  data_dir: /tmp/mimir/alertmanager
  external_url: http://localhost:9009/alertmanager
  enable_api: true                     # ADD (to POST AM config)

# ADD new top-level section (C12: distinct prefix, no collision with blocks)
alertmanager_storage:
  backend: s3
  s3:
    endpoint: s3.us-east-1.amazonaws.com
    region: us-east-1
    bucket_name: lgtm-metrics-us-east-1-123456789012
  storage_prefix: alertmanager
```
Keep `ruler_storage.backend: filesystem` (rules are small, mounted read-only, re-provisioned on restart) **OR** switch to S3 with `storage_prefix: ruler`. Recommendation: **keep filesystem** for rules (simpler, avoids a second prefix and API-vs-file authority conflict) and use S3 only for alertmanager config persistence. `[NEEDS-VERIFY]` `mimir -modules -config.file=...` accepts `alertmanager_storage` on 2.14.1 before apply.

### C4. Enable the alertmanager module — `docker-compose.yml` line 105
```yaml
    command: -target=all,alertmanager -config.file=/etc/mimir/config.yaml
```
Adds ~50–100MB RAM; ample headroom on a 32GB box.

### C5. Mount rule files — `docker-compose.yml` mimir `volumes:`
```yaml
      - ./config/mimir/rules/demo:/tmp/mimir/ruler-storage/demo:ro
```

### C6. Alertmanager config with native SNS (C7 — no webhook shim)
POST via AM API after startup (or seed to S3 `alertmanager/demo/`). AM config uses the **upstream-Prometheus `sns` receiver**:
```yaml
route:
  receiver: sns-critical
  group_by: [alertname, service_name]
  routes:
    - matchers: [severity="critical"]
      receiver: sns-critical
    - matchers: [severity="warning"]
      receiver: sns-critical
receivers:
  - name: sns-critical
    sns_configs:
      - topic_arn: <ARN from Terraform output>
        sigv4: {region: us-east-1}
        attributes: {severity: critical}
```
Post: `curl -s -H 'X-Scope-OrgID: demo' -X POST --data-binary @alertmanager.yaml http://localhost:9009/api/v1/alerts` (Mimir AM config API). `[NEEDS-VERIFY]` exact API path/format on 2.14.1 (`/api/v1/alerts` config vs `mimirtool alertmanager load`).

### C7. SNS topic + IAM publish — `main.tf` (C9: must be created)
```hcl
resource "aws_sns_topic" "lgtm_alerts" {
  name = "lgtm-stack-alerts"
}
resource "aws_sns_topic_subscription" "lgtm_alerts_email" {
  topic_arn = aws_sns_topic.lgtm_alerts.arn
  protocol  = "email"
  endpoint  = "devops@example.com"   # requires MANUAL confirmation click
}
resource "aws_iam_role_policy" "lgtm_sns_publish" {
  name = "lgtm-sns-publish"
  role = aws_iam_role.lgtm_instance_role.id   # matches s3-backends.tf role ref
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sns:Publish", "sns:GetTopicAttributes"]
      Resource = [aws_sns_topic.lgtm_alerts.arn]
    }]
  })
}
output "lgtm_alerts_topic_arn" { value = aws_sns_topic.lgtm_alerts.arn }
```

### Delivery path decision
**Use Mimir Alertmanager `sns_configs` (SigV4 via instance role).** Rationale: Mimir AM is already in-process once §C4 lands; the upstream-Prometheus AM has a native `sns` receiver; the EC2 role gets `sns:Publish` (§C7). This keeps all rule-based alerting on one delivery path. Grafana-native SNS contact points (C7) remain available as an alternative for Grafana-managed alerts but are **not** used here to avoid two delivery systems.

### C validation
1. `docker-compose restart mimir`; `docker-compose logs mimir | grep -i alertmanager` shows the module started; startup clean (prefix-collision guard).
2. `curl -s -H 'X-Scope-OrgID: demo' http://localhost:9009/prometheus/api/v1/rules` lists `red-recording` + `stack-alerts`.
3. Recording: `curl -s -H 'X-Scope-OrgID: demo' 'http://localhost:9009/prometheus/api/v1/query?query=service:requests:rate5m'` returns data within one eval interval.
4. SNS: `aws sns publish --topic-arn <arn> --message test` → email arrives (after subscription confirmed). Then trip `HighServiceErrorRatio` or temporarily lower a threshold to confirm end-to-end AM→SNS.
5. `[NEEDS-VERIFY]` subscription state `CONFIRMED`: `aws sns list-subscriptions-by-topic --topic-arn <arn>`.

### C rollback
- Rules: unmount volume / delete files → `docker-compose restart mimir`.
- AM module: revert `-target=all,alertmanager` → `-target=all`; remove `alertmanager_storage`.
- SNS: `terraform destroy -target=aws_sns_topic.lgtm_alerts` (and IAM/subscription).
Each independently revertible.

---

## Phase D — Stack self-health + external dead-man's-switch (Terraform)

**Scope:** `main.tf`, `config/cloudwatch-agent-config.json`. Fully out-of-band from the LGTM data plane — cannot re-trigger ingestion/cardinality/live_traces issues.
**Confidence: HIGH for the CloudWatch-native alarms; the internal-metrics scrape is optional and MEDIUM.**

### D1. External dead-man's-switch (ship first, highest value, zero data-plane risk)
`main.tf` — wire to the Phase-C SNS topic:
```hcl
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "lgtm-ec2-statuscheck-failed"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.lgtm.id }   # [NEEDS-VERIFY] instance resource name
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.lgtm_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "cw_agent_silent" {
  alarm_name          = "lgtm-metric-absence-cpu-idle"
  namespace           = "LGTM/EC2"
  metric_name         = "cpu_usage_idle"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"        # metric silence = agent/host dead
  alarm_actions       = [aws_sns_topic.lgtm_alerts.arn]
}
```
`[NEEDS-VERIFY]` the `LGTM/EC2` metric carries an InstanceId dimension — if so, add `dimensions` or use a Metrics-Insights alarm to avoid ambiguity.

### D2. Fix the broken CloudWatch log source (C11) — `config/cloudwatch-agent-config.json`
The current `/var/log/docker` file path is wrong for the json-file driver. If per-container stderr shipping is wanted, point at `/var/lib/docker/containers/*/*.log`. Otherwise leave the existing daemon/system log collection as-is and **do not** add the broken path. Recommendation: minimal — do not expand container-log shipping in this workstream (app logs already go to CloudWatch via the app).

### D3. Container liveness (concrete, not hand-waved — C's flaw)
The `SpanMetricsPipelineSilent` alert (§C2) already covers "collector pipeline dead". For per-container liveness, the concrete mechanism is the CloudWatch agent **`procstat`** plugin (match on process name) emitting a metric, alarmed with `treat_missing_data=breaching`. Do **not** rely on `docker exec healthchecks` (hand-wave). This is optional; ship only if per-container granularity is required beyond the pipeline meta-alert.

### D4. [OPTIONAL / deferred] Ingest internal metrics to unlock the deferred alerts (HC1)
To alert on `tempo_discarded_spans_total{reason="live_traces_exceeded"}` and `tempodb_compaction_outstanding_blocks` (the *incident's own early-warning signals*), add a `prometheus` receiver to the collector scraping `tempo:3200/metrics` + `mimir:9009/metrics` into a metrics pipeline → `prometheusremotewrite/mimir`. Then add those two alerts. `[NEEDS-VERIFY]` scrape cardinality impact on the 30k/60k limit before enabling — this is the one Phase-D item that touches the ingestion path, so it is deferred/optional and gated on a cardinality check. **High value** because it directly monitors the metric that trips the live-traces incident.

### D validation
1. `terraform plan` clean; `terraform apply`.
2. `aws cloudwatch describe-alarms --alarm-names lgtm-ec2-statuscheck-failed lgtm-metric-absence-cpu-idle`.
3. Simulate agent-down: `sudo systemctl stop amazon-cloudwatch-agent` on-box → within ~10min alarm → SNS email.
4. Confirm SNS email received.

### D rollback
`terraform destroy -target=<alarm>` per resource. CW-agent config: `git revert` + re-fetch agent config. No data-plane touch.

---

## §3 — The double-emit resolution (span-metrics / service-graphs)

**Current state:** BOTH emit to Mimir/`demo`:
- **Collector connectors** → `traces_span_metrics_*` (underscore) + `traces_service_graph_*`, computed on the **full pre-sample** stream. This is the intended RED/service-graph source (unbiased) and what Phase A/C target.
- **Tempo `metrics_generator`** (`metrics_generator_processors: [service-graphs, span-metrics, local-blocks]`) → `traces_spanmetrics_*` (no underscore between span/metrics) + its own `traces_service_graph_*`, computed on the **tail-sampled** stream Tempo receives.

**Are they double-counting?** Not on the *same series* — the connector span-metric name is `traces_span_metrics_*`, the generator's is `traces_spanmetrics_*`; these are distinct time series, so no arithmetic double-count. **BUT** `traces_service_graph_*` collides by name — both processors emit that name, differentiated only by the generator's `external_labels: {source: tempo}`. That is a genuine partial overlap on service-graph series and a source of confusion for `serviceMap`.

Per MEMORY (`lgtm-prod-evolution-decisions`), after B1 the generator span-metrics path reads the **sampled** subset and is effectively starved/low — but it is **not** disabled, so it still emits (sample-biased) `traces_spanmetrics_*` and `traces_service_graph_{source="tempo"}`.

**Recommendation (sequenced, do LAST — after Phase A dashboards consume the connector series):**
1. Keep `local-blocks` in `metrics_generator_processors` — **required** for the 13 demo-service TraceQL-metrics dashboards. (Non-negotiable.)
2. Remove `service-graphs` and `span-metrics` from `metrics_generator_processors` so only `local-blocks` remains:
   ```yaml
   metrics_generator_processors:
     - local-blocks
   ```
   This eliminates the sample-biased duplicate `traces_spanmetrics_*` and the colliding `traces_service_graph_{source="tempo"}`, leaving the connectors as the single unbiased source. `local-blocks` does not remote_write span/service-graph metrics, so TraceQL dashboards are unaffected.
3. **[NEEDS-VERIFY before applying]** Confirm no dashboard/panel queries `traces_spanmetrics_*` (old name) or `traces_service_graph_{source="tempo"}`. Grep the demo-service dashboards; if any panel uses the generator series, migrate it to the connector series first (that's the "dashboards must consume PromQL first" gate the collector-config header already warns about).

**Confidence: MEDIUM** — depends on the dashboard grep. If any dashboard still reads the generator series, do NOT remove those processors yet.

---

## §6 — App/SDK vs pure-stack scope

| Item | Scope |
|---|---|
| Phase A (correlation datasources) | **Pure stack config.** |
| Phase B exemplar **storage** (`max_global_exemplars_per_user`) | **Pure stack config.** |
| Phase B exemplar **resolution for qa** (sampled-out 404s) | **[APP/SDK or sampling policy — OUT OF SCOPE].** Only in-stack mitigation is scoping panels to dev/prod. |
| Exemplar **emission** (trace_id on samples) | Already done by the connector; **no app change needed** for connector series. App-side exemplars on native app metrics would be SDK work (out of scope). |
| Phase C recording/alerting/AM/SNS | **Pure stack + Terraform.** No app change. (C's "needs-app-or-sdk-change" effort tag was wrong.) |
| Phase D alarms + dead-man's-switch | **Pure Terraform/config.** No app change. |
| Phase D4 internal-metrics scrape | **Pure stack config** (collector receiver) but touches ingestion → gated. |

---

## §7 — Risk register (esp. not re-triggering the incident)

| ID | Risk | Phase | Mitigation | Confidence |
|---|---|---|---|---|
| **R1** | Exemplar storage raises Mimir sample/series load → `err-mimir-tenant-max-ingestion-rate` (the exact 30k limit that fired before) | B | Exemplars ride existing series (do not create new series); watch `ingestion_rate` headroom post-enable; 100k is a bounded ring. Roll back = one line. | MEDIUM |
| **R2** | Mimir refuses to start on shared bucket+prefix | C | Distinct `storage_prefix: alertmanager`; keep ruler on filesystem; `mimir -modules` dry-check before apply. | HIGH (guarded) |
| **R3** | `-target=all,alertmanager` OOM / restart | C | +~100MB on a 32GB box; monitor after restart. | HIGH |
| **R4** | Silent no-op alerts (rules on non-existent series) | C | Excluded by design — only ship rules on verified-present series; internal-metric alerts deferred to D4 behind a scrape. | HIGH |
| **R5** | Removing generator processors breaks a demo-service dashboard | §3 | Gated on dashboard grep; `local-blocks` retained for TraceQL. Do last. | MEDIUM |
| **R6** | live_traces_exceeded regression | none directly | No phase raises trace inflow or sampling %; `max_live_traces` (100k) and tail-sampling untouched. D4 scrape adds metrics, not traces. | HIGH |
| **R7** | SNS silent failure (unconfirmed email / missing IAM) | C/D | `sns:Publish`+`GetTopicAttributes` in IAM; verify subscription `CONFIRMED`; send test publish. | HIGH |
| **R8** | Cardinality blow-up from D4 scrape of `/metrics` | D4 | Deferred/optional; measure series count against 30k limit before enabling; scope scrape to needed metrics. | MEDIUM |
| **R9** | Duplicate alerts (Loki+Mimir both firing) | — | Eliminated: Loki ruler dropped entirely (C6); all rules owned by Mimir. | HIGH |

---

## Recommended ship order (each independently deployable + reversible)
1. **Phase A** (datasources) — immediate, zero risk.
2. **Phase D1** (StatusCheckFailed + metric-absence alarms + SNS topic from §C7 pulled forward) — highest safety value, out-of-band. *Note: §C7 SNS topic is a shared prerequisite for both C and D; create it here.*
3. **Phase B** (exemplar storage) — after A, watch R1.
4. **Phase C** (rules + AM module + SNS delivery) — after SNS topic exists.
5. **§3 double-emit cleanup** — LAST, gated on dashboard grep.
6. **Phase D4** (internal-metrics scrape + incident early-warning alerts) — optional, gated on cardinality (R8), unlocks the live_traces_exceeded alert.

## Open items to verify on-box before/at apply (do not assert blind)
- `[NEEDS-VERIFY]` connector series present: `.../label/__name__/values | grep traces_span_metrics` (A/B/C).
- `[NEEDS-VERIFY]` `mimir -modules` accepts `alertmanager_storage` + `-target=all,alertmanager` on 2.14.1 (C).
- `[NEEDS-VERIFY]` Mimir 2.14.1 AM config API path/format (`/api/v1/alerts` vs `mimirtool`) (C).
- `[NEEDS-VERIFY]` `sns_configs` supported in Mimir's bundled AM version (C).
- `[NEEDS-VERIFY]` `aws_instance` resource name in `main.tf` for the alarm `dimensions` (D1).
- `[NEEDS-VERIFY]` `LGTM/EC2 cpu_usage_idle` dimension shape for the absence alarm (D1).
- `[NEEDS-VERIFY]` no demo-service dashboard reads `traces_spanmetrics_*` / `traces_service_graph_{source="tempo"}` before §3 removal.
- `[NEEDS-VERIFY]` Loki streams carry `service_name`/`job` labels for tracesToLogsV2 to return results (A) — feature is wired regardless.

Relevant files (repo-relative): `config/grafana/provisioning/datasources/datasources.yaml`, `config/mimir-config.yaml`, `config/otel-collector-config.yaml`, `config/tempo-config.yaml`, `config/loki-config.yaml`, `docker-compose.yml`, `main.tf`, `s3-backends.tf`, `config/cloudwatch-agent-config.json`, and new files `config/mimir/rules/demo/red-recording.yaml` + `config/mimir/rules/demo/stack-alerts.yaml`.