# Runbook: CollectorTailSamplingDroppingTraces

**Alert:** `otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total` rate > 0
(critical). Traces are evicted from the tail_sampling buffer BEFORE their sampling decision
completes, so they are marked unsampled and NOTHING reaches Tempo.

**This class can run at 100% of traffic for hours in complete silence** when the collector's own
telemetry is not scraped into Mimir. That is the whole reason the internal-telemetry scrape job and
this alert exist. Without them the symptom presents as "only one service appears in Explore", and
nobody looks at the collector.

## What it means
`num_traces` (the in-memory ring buffer) is smaller than the working set of traces in flight during
`decision_wait`. The working set is roughly:

    traces/sec x decision_wait

When the ingest rate rises above what `num_traces` holds for `decision_wait` seconds, the oldest
traces are evicted unjudged.

## First response
1. Confirm the drop and check whether anything is still being sampled:
   - `rate(otelcol_processor_tail_sampling_sampling_trace_dropped_too_early_total[5m])` — dropping.
   - `rate(otelcol_processor_tail_sampling_count_traces_sampled_total[5m])` — should be >0.
   - `otelcol_processor_tail_sampling_sampling_traces_on_memory` against the configured `num_traces`.
     This is a GAUGE, so it has no `_total` suffix.
2. Confirm traces stopped reaching Tempo: `tempo_live_store_traces_created_total` is frozen.
   The Tempo image is distroless, so `docker exec` gives you no shell — read
   `curl localhost:3200/metrics` from the host instead.
3. Measure the REAL rate before you change anything:
   `rate(otelcol_receiver_accepted_spans_total[5m])` divided by the average spans per trace.

## Fix
Raise `num_traces` in `config/otel-collector-config.yaml` under tail_sampling, so it comfortably
exceeds (rate x decision_wait), and set `expected_new_traces_per_sec` to the measured rate. Validate
the config, deploy, then confirm two things move: `count_traces_sampled_total` climbs, and
`traces_created_total` unfreezes.

If the alert fires again, the rate grew. Re-measure and raise both values. Do not guess.
