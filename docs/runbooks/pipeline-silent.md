# Runbook: span-metrics pipeline silent or implausibly low

**Alerts:**
- `SpanMetricsPipelineSilent` (critical) — no `traces_span_metrics_calls_total` at all for 3m+.
- `ProdSpanMetricsPipelineSilent` (critical) — the same, scoped to live envs.
- `SpanMetricsPipelineImplausiblyLow` / `ProdSpanMetricsPipelineImplausiblyLow` (warning) — the
  pipeline is alive but the rate is far under a plausible normal.
- `ApplicationMetricsAbsent` (warning) — no application-emitted `http_*` metric family in Mimir.

## Read the floors and the silence detectors together

**A TRICKLE DEFEATS AN EQUALITY TEST.** The `== 0` detectors only fire on total silence. A
partial-failure mode can leave RED metrics reporting a fraction of a percent of real traffic — with
the busiest service reading literally 0/s — while the global aggregate holds a small residual well
above zero. `SpanMetricsPipelineSilent` then never fires.

That is what the two `ImplausiblyLow` alerts exist for, and it is why they are `> 0 and < N` rather
than a plain `< N`: strictly complementary, so a real total outage pages once, not twice.

**If either floor alert is firing, do not trust ANY RED or SLO number until you have explained it.**

## First response
1. **Is the collector alive?**
   `docker compose ps otel-collector` and `curl -s localhost:13133/` for its health endpoint.
2. **Collector logs:** `docker compose logs --tail 100 otel-collector`. Look for OOM from the
   memory_limiter, config errors, or export failures to Mimir.
3. **Are traces arriving at all?** `rate(otelcol_receiver_accepted_spans_total[5m])`.
   If the receiver sees nothing, the problem is UPSTREAM — all services stopped sending, or the
   network path is broken — and it is not a collector fault.
4. **Is the collector exporting?** `rate(otelcol_exporter_send_failed_metric_points_total[5m])`.
   See [collector-export.md](collector-export.md).
5. **For a floor alert specifically, check duplicate-timestamp discards FIRST.**
   `sum by (reason) (rate(cortex_discarded_samples_total[5m]))`
   A large duplicate-timestamp rate means two writers are colliding on one series, and the collapse
   is happening in Mimir rather than in the collector. See [mimir-discards.md](mimir-discards.md).

## Common causes
- Collector OOM or restart. Check `mem_limit` and GOMEMLIMIT.
- A bad collector config after a deploy. Always `validate --config` before applying.
- A total upstream outage — every service down, or a network partition.
- **Resource collapse in the spanmetrics connector.** If the connector emits one ResourceMetrics per
  process with no resource-distinguishing dimension, every process of a service collides on one label
  set and the great majority of samples are discarded as duplicate-timestamp. This is the floor-alert
  cause, and it is invisible to the `== 0` detectors by construction.

## `ApplicationMetricsAbsent`

Different question: the collector-derived series (`traces_span_metrics_*`, `otelcol_*`, hostmetrics)
may be perfectly healthy while NO application emits a metric of its own. The stack looks alive and
per-service RED from the apps themselves is gone.

Check, in order:
1. Does the deployed instrumentation package export metrics at all? Some versions hard-code an empty
   metric-reader list, which makes the endpoint variable inert. That is a version floor, not a
   provisioning gap.
2. Does the deployed task definition still carry the OTLP metrics endpoint variable?
3. Is the collector's `metrics` pipeline exporting?

**Before you treat this as an outage, rule out a metric RENAME.** The rule uses `absent()`, which
fails LOUD on a selector that has merely gone stale — a rename is indistinguishable from an outage.
List what the fleet actually emits:

```promql
count by (__name__) ({__name__=~"http_.*_count"})
```

If a healthy family is flowing under a name the rule does not match, WIDEN the selector. Do not swap
one name for another: during a fleet migration both semconv generations coexist, and a rule that
matches only one is really tracking "is the last service on old instrumentation still deployed".

## Escalate
Critical. The observability stack is blind to traces while a silence alert fires, and it is
misleading — worse than blind — while a floor alert fires.
