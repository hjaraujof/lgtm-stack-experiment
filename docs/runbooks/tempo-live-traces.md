# Runbook: Tempo live_traces_exceeded

**Alerts:**
- `TempoLiveTracesExceeded` (critical) — Tempo dropping spans with `reason="live_traces_exceeded"`.
  This is the precursor to a disk-full / trace-bleed incident.
- `TempoLiveTracesHigh` (warning) — proactive: `tempo_live_store_live_traces > 32000`, which is 80% of
  the 40000 `max_traces_per_user` cap, firing BEFORE discards begin.

## What it means
Tempo 3.x removed the 2.x metrics-generator `local_blocks` and `ingester` modules. The distributor
now writes into an in-process **live-store**, and the live-trace guardrail is the per-tenant
`overrides.defaults.ingestion.max_traces_per_user` cap in `config/tempo-config.yaml`. When concurrent
distinct live traces reach that cap, the live-store discards new-trace spans.

**THIS IS A CONCURRENT-LIVE-TRACES CAP, NOT A THROUGHPUT CAP.**

    live_traces  ~=  incoming_trace_rate  x  trace_lifetime

So a firehose of very short traces can pin it just as easily as a slow trickle of very long ones, and
the two need opposite fixes. Establish which term grew before you touch anything.

## First response
1. **Current live traces against the cap.** Query `sum(tempo_live_store_live_traces)` in Mimir.
   The Tempo image is distroless, so prefer the Mimir query over `docker exec`. Compare with
   `max_traces_per_user` in `config/tempo-config.yaml`.
2. **Discard rate:** `rate(tempo_discarded_spans_total{reason="live_traces_exceeded"}[5m])`.
   Above 0 means actively dropping.
3. **Disk headroom:** `df -h /`. With object-store backends the disk-full failure mode is largely
   removed, but above 85% treat this as the disk-full track.
4. **Where is the volume from, and is it the rate or the lifetime?**
   For a TRUE trace rate use `sum(rate(traces_service_graph_request_total[5m]))`, or a single
   tail_sampling policy's `count_traces_sampled_total`. Do NOT use
   `traces_span_metrics_calls_total` — that is measured AFTER the bookkeeping-drop filter and reads
   far lower than reality.
   Then confirm tail sampling still holds the noisy pre-production env at its sampled rate. A sampling
   regression floods the live-store, and it is the most common cause here.
5. **Is the flush and compaction path healthy?** Cross-check `TempoCompactionStalled`. A stalled flush
   lets live traces accumulate even at a normal ingest rate.

## Common causes
- A sampling regression, so a high-volume env is no longer sampled. Flood of concurrent live traces.
- A genuine traffic spike, or an upstream runaway such as a background loop emitting a trace firehose.
- The cap is simply set too low for real steady state.
- Flush or compaction stalled, so nothing drains.

## Remediation levers
- **Raise `max_traces_per_user`** in `overrides.defaults.ingestion`, incrementally, and watch
  live-store RAM. A Tempo restart applies it. **Move `TempoLiveTracesHigh` to 80% of the new cap in
  lockstep** — otherwise the warning fires constantly at the healthy new baseline, and it will be
  silenced.
- **Source-cut the trace volume** at the collector or at the emitting service. Preferred when the
  volume is a runaway or is low-value spans: it gives fewer concurrent traces without more memory.

## Escalate
Critical plus a disk approaching full means the box may become unreachable. Use a break-glass console
path before it locks up, not after.

If the volume is an application runaway rather than a stack misconfiguration, the fix is source-side.
Hand it to the emitting service's owners.
