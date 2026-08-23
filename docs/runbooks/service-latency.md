# Runbook: service latency SLI breach

**Alert:** `ServiceLatencySLIBreach` — fewer than 95% of a service's **inbound requests** served under
250ms over 30m, sustained 15m (warning). Fires even with zero errors.

## What it means
The service is slow, not necessarily failing. `service:latency_fast_ratio:30m`, the fraction under the
250ms histogram bucket, dropped below 95%.

**IT MEASURES SERVER SPANS ONLY, AND THAT IS LOAD-BEARING.** A rule that counts every span kind
measures instrumentation volume rather than user-visible latency. A service that emits several hundred
INTERNAL spans per inbound request has its real fast-ratio diluted by that noise, so a genuine
regression is MASKED; and a service that serves 100% of inbound requests under the threshold can
BREACH for a sustained stretch purely on internal spans. Under an unfiltered rule, adding
instrumentation moves the "SLO" with no user-visible change at all.

If you are comparing against a number someone quoted from an all-kinds version of this rule, it is
not the same metric.

CLIENT spans are deliberately excluded: a slow outbound call is the CALLEE's latency, and the callee
already counts it in its own SLI. If this service looks slow but its own handlers are fast, look at
what it calls — that is a downstream breach, and the downstream service should be alerting separately.

## First response
1. Confirm in Grafana: `service:latency_p95_ms:5m{service_name="<svc>"}` and
   `service:latency_p99_ms:5m{service_name="<svc>"}` on the RED dashboard row.
2. Find slow traces. In Explore against Tempo:
   `{resource.service.name="<svc>" && duration>250ms}`, or click a latency-panel exemplar to open a
   slow trace directly.
3. In the trace, find the dominant span: a DB call, a downstream HTTP request, or a lock wait.

## Before you treat a breach as real
Check the sample count in the window: `sum by (service_name) (increase(traces_span_metrics_duration_milliseconds_count{span_kind="SPAN_KIND_SERVER"}[30m]))`

The alert gates at >300 requests per 30m for a reason. At n=300 and p about 0.95 the ratio's standard
error is roughly 1.3pp, which is small against the 5pp threshold band. Below that the ratio is
sparse-window noise and a "breach" means nothing. A sparse service typically shows a flat few-millisecond
p99 while its fast-ratio swings between 0 and 1.

## Common causes
- A slow DB query.
- Downstream latency. Check the service-graph edge duration.
- Resource pressure on the host. This stack is CPU-bound, and heavy query load can itself slow request
  handling — so a latency breach can be caused by someone running an expensive dashboard.

## Escalate if
p99 keeps climbing, or a single downstream dependency is clearly the bottleneck.
