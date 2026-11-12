# Runbook: the Loki ruler's recorded series are missing from Mimir

**Alerts:** `LokiRulerRemoteWriteFailing`, `LokiRulerNotAppending` (both warning).
Rules: `config/mimir/rules/demo/stack-alerts.yaml`. Tests:
`tests/mimir-rules/loki-ruler-remote-write.test.yaml`.

## What it means

The Loki ruler evaluates the recording rules in `config/loki/rules/demo/` and remote-writes the
result to Mimir (`config/loki-config.yaml`, `ruler.remote_write`). These two alerts split the one
visible symptom - `stack:loki_ruler_heartbeat:5m` going stale or absent in Mimir - into its two
causes:

| Alert | Cause | Where to look first |
|---|---|---|
| `LokiRulerRemoteWriteFailing` | the ruler evaluates, the send fails non-recoverably | Mimir ingest limits, then the Loki ruler log |
| `LokiRulerNotAppending` | no samples are produced at all, OR the counter is gone from Mimir | the Loki ruler API, then the collector filters |

`samples_failed_total` counts **non-recoverable** sends only. A recoverable error is retried, so
every increment is a recorded sample that is permanently lost.

## First response

Tenant is `demo` and Loki runs `auth_enabled: true`. **Every Loki call below needs
`X-Scope-OrgID: demo`.** Without the header the request resolves to another tenant and returns
nothing, which reads exactly like the outage.

Open an SSM session on the box (the `ec2-ssm-access` skill in `.claude/skills/` has the recipe), then:

1. **Are the rules loaded?** Empty or HTTP 400 means the ruler never loaded them, and no
   remote-write is expected:
   ```bash
   curl -s -H 'X-Scope-OrgID: demo' http://localhost:3100/loki/api/v1/rules
   ```
2. **What do the counters say on the box?** This is the authoritative read - the alert sees only
   what the collector relayed:
   ```bash
   curl -s http://localhost:3100/metrics | grep -E \
     'loki_ruler_wal_(samples_appended_total|prometheus_remote_storage_samples(_failed)?_total)'
   ```
   - `samples_appended_total` climbing, `samples_failed_total` climbing → remote-write is failing.
   - `samples_appended_total` flat → the ruler is producing nothing. Go to step 4.
   - the names are **absent from `/metrics` entirely** → a Loki upgrade renamed them. Fix the
     collector filters (below) to match, or the alerts are inert.
3. **Why is the send failing?** The ruler logs the remote-write error:
   ```bash
   docker-compose logs --tail 200 loki | grep -iE 'remote|wal|429|4[0-9][0-9]|5[0-9][0-9]'
   ```
   A `429` is a Mimir ingest limit - see `docs/runbooks/mimir-discards.md`. A `400` is usually an
   out-of-order or duplicate sample, which happens if two producers write the same series name.
4. **Is Loki receiving logs at all?** The heartbeat rule is
   `sum(count_over_time({service_name=~".+"}[5m]))`, and `sum()` over no matching lines returns an
   **empty vector**, so a stack receiving nothing appends nothing - legitimately, as far as the
   ruler is concerned, and an incident of its own:
   ```bash
   curl -s -G -H 'X-Scope-OrgID: demo' http://localhost:3100/loki/api/v1/query \
     --data-urlencode 'query=sum(count_over_time({service_name=~".+"}[5m]))'
   ```

## If the counter is absent from Mimir but present on the box

Then the collector is dropping it, and this is the failure mode the alert set was built around. A
metric from Loki's `/metrics` must pass **two independent filters** in
`config/otel-collector-config.yaml`, and a name in only one of them keeps **nothing**, with no
error logged anywhere:

1. the `loki-internal` scrape job's keep-only `metric_relabel_configs` regex, and
2. the `filter/internal_metrics` processor's allowlist - one long
   `name != "x" and name != "y" and ...` drop condition.

Two traps:

- The allowlist already contains `prometheus_remote_storage_samples_failed_total`. That is
  **Mimir's own** counter. The Loki ruler's carries the `loki_ruler_wal_` prefix and is a
  different string.
- The `_total` suffix is required at **both** ends for a `loki_*` name. Loki serves standard
  Prometheus exposition, so the suffix is present at scrape and is what Mimir stores. Only the
  collector's own `:8888` target uses suffix-free OTel-native names.

After editing that file:

```bash
# the config is a SINGLE-FILE bind mount, so the inode is pinned: `docker restart` keeps serving
# the old content, and `up -d` without --force-recreate exits 0 having changed nothing.
docker-compose --profile ssl up -d --force-recreate otel-collector

# the image is distroless, so `docker exec ... grep` fails. Read the container's OWN copy:
docker cp otel-collector:/etc/otelcol-contrib/config.yaml /tmp/live.yaml
# 3 names x 2 filters = 2 occurrences of each name OUTSIDE the comments. Count them that way:
# a plain `grep -c` also matches the explanatory comments and passes on a half-applied edit.
grep -v '^\s*#' /tmp/live.yaml | grep -o 'loki_ruler_wal_[a-z_]*' | sort | uniq -c
```

Then confirm the series **arrives**, because a config that parses is not a metric that ships:

```bash
curl -s -G http://localhost:9009/prometheus/api/v1/query -H 'X-Scope-OrgID: demo' \
  --data-urlencode 'query=loki_ruler_wal_samples_appended_total'
```

## Escalate

Neither alert is customer-facing: the affected series are this stack's own liveness instruments.
Escalate only if the same investigation shows Loki dropping or refusing log ingest - that is
`LokiSamplesDiscarded` / `docs/runbooks/loki-discards.md` territory and does lose data.
