# Runbook: Mimir active series high (cardinality)

**Alert:** `MimirActiveSeriesHigh` — `cortex_ingester_memory_series > 400000` for 30m (warning).

400k is 80% of the explicit `max_global_series_per_user: 500000` cap in `config/mimir-config.yaml`,
so this warns BEFORE Mimir starts discarding series at the cap.

**Check the two numbers agree.** If the alert threshold sits ABOVE the cap it can never fire, and
the first sign of trouble becomes silent series loss. That is a real failure mode, not a hypothetical.

## What it means
Active series are approaching the per-tenant cap. At the cap, new series are discarded — which
surfaces as `MimirSamplesDiscarded` with reason `per_user_series_limit` — and RED metrics lose
fidelity. Series growth is also the named RAM-scaling risk for this stack.

## First response
1. Use the cardinality analysis API (`cardinality_analysis_enabled: true` in mimir-config.yaml):
   ```
   curl -H 'X-Scope-OrgID: demo' 'http://localhost:9009/prometheus/api/v1/cardinality/label_names'
   curl -H 'X-Scope-OrgID: demo' 'http://localhost:9009/prometheus/api/v1/cardinality/label_values?label_name=<suspect>'
   ```
2. The most likely cause is a high-cardinality dimension leaking into spanmetrics or servicegraph:
   an unbounded `span_name`, a per-request id, or a newly added dimension. Read
   `spanmetrics.dimensions` and `servicegraph.dimensions` in the collector config.
3. Confirm which metric family is growing:
   `topk(10, count by (__name__)({__name__=~"traces_.*"}))`

## Fix levers, in order of preference
1. Remove or bound the offending dimension AT THE COLLECTOR. That is the source of the cardinality,
   and it is the only lever that reduces CPU as well as series count.
2. Normalize high-cardinality span names. The `transform/normalize_names` processor already strips
   query strings and templates ids out of URL paths — extend it when a new pattern leaks.
3. Raising `max_global_series_per_user` is a stopgap. It buys time and costs RAM.

Whichever lever you pull, remember `SpanMetricsFlushApproachingBurstLimit` reads a coupled number.
The burst limit and the series cap are separate limits with separate alerts.
