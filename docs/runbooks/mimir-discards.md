# Runbook: Mimir samples discarded

**Alerts:**
- `MimirSamplesDiscarded` (warning): discards for any reason EXCEPT duplicate-timestamp and
  out-of-order, for 5m.
- `MimirDuplicateOrOutOfOrderSamples` (warning): duplicate-timestamp or out-of-order discards above a
  floor of 10/s, for 15m.
- `SpanMetricsFlushApproachingBurstLimit` (warning): the spanmetrics flush payload is above 70% of
  `ingestion_burst_size`. This one fires BEFORE any data is lost.

## What it means
Mimir is rejecting samples, so the recorded RED series are undercounting. Worse, the stored counters
stay monotonic while this happens, so dashboards continue to look healthy.

## First response
1. Break it down by reason. Always start here:
   `sum by (reason) (rate(cortex_discarded_samples_total[5m]))`

2. **`rate_limited`** — the collector is pushing more than `ingestion_rate` allows.
   READ THIS BEFORE YOU RAISE THE RATE. The spanmetrics connector ships its ENTIRE cache in one
   write each `metrics_flush_interval`, so the binding constraint is usually
   `ingestion_burst_size`, not `ingestion_rate`. The error message names the rate and means the
   burst. Raising the rate alone changes nothing.
   Check the flush payload: `count(traces_span_metrics_calls_total) * 15`, where 15 is
   (histogram buckets + 3). Compare that against `ingestion_burst_size`.

3. **`per_user_series_limit`** — cardinality growth. See [mimir-cardinality.md](mimir-cardinality.md).

4. **`sample_duplicate_timestamp` / `sample-out-of-order`** — TWO WRITERS ARE COLLIDING ON ONE SERIES.
   This is the reason with the worst failure history, so treat it seriously even at a low rate.
   Check in this order:
   - `spanmetrics.resource_metrics_key_attributes` in the collector config. If the connector emits
     one ResourceMetrics per process with NO resource-distinguishing dimension, every process of a
     service collides on one label set. This can silently discard the large majority of every sample
     pushed, and it undercounts RED metrics by orders of magnitude while never reaching exactly zero
     — so the `== 0` pipeline detectors stay quiet. `SpanMetricsPipelineImplausiblyLow` exists for
     precisely this.
   - `honor_timestamps: false` on the self-scrape jobs, which addresses a same-receive-second
     collision among the internal gauge series.
   - Application clock skew, or a producer double-sending.
   Watch the `mimir:self_scrape_dup:rate5m` recording rule for your own residue baseline, and set
   the alert floor just above its observed ceiling.

5. **`sample_out_of_bounds` / `greater_than_max_sample_age`** — clock skew, or a backfilling client.

## A warning about measuring an active discard storm
Every query above reads a Mimir-backed metric, so during a storm they are fed the same lossy stream
as everything else. `count()` over a series SET is far more robust than a `rate()`, because the series
exist once created. If a number looks suspiciously flat mid-incident, scrape the collector's own
`/metrics` endpoint directly and trust that instead.

## Fix levers
Raising a limit (config plus restart) is a stopgap. Prefer cutting source cardinality at the
collector: on a CPU-modest host, limits have a ceiling and the source cut is the only real lever.
