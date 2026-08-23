# Runbook: service error budget / availability

**Alerts:** `HighServiceErrorRatio` (>5% over 5m, warning), `ServiceErrorBudgetFastBurn`
(>14.4x on 1h+5m, critical), `ServiceErrorBudgetSlowBurn` (>6x on 6h+30m, warning),
`ServiceAvailabilitySLIUnmeasurable` (no status-code coverage, warning).

SLO baseline: 99% availability, a 1% error budget. **That budget is a placeholder** — tune it per
service once you have measured baselines. The multi-window structure is the correct part.

## What it means
The service is returning errors above its budget. A fast burn means the budget is gone in about 2
days, so it pages. A slow burn means it is trending to breach, so it tickets.

## What the numerator is, and why

These alerts measure `service:http_5xx_ratio:{5m,30m,1h,6h}` — **the fraction of inbound HTTP requests
answered 5xx**:

```promql
sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER",http_response_status_code=~"5.."}[30m]))
  / clamp_min(sum by (service_name) (rate(traces_span_metrics_calls_total{span_kind="SPAN_KIND_SERVER",http_response_status_code!=""}[30m])), 1e-9)
```

**NOT span status across every span kind.** That form counts instrumentation depth, not failures: one
failing request marks every decorated method span it touches, so a service that ADDS spans "gets
worse" with no user-visible change. A service can show a SERVER error ratio of exactly 0, an INTERNAL
ratio of 0.08, and a 6h all-kinds ratio of 0.069 against a 0.06 threshold — and page on the third
number while nothing is wrong.

Two consequences when you read a breach:

- **A benign-error floor cannot reach this numerator.** A caught-and-handled internal error sets
  STATUS_CODE_ERROR on an INTERNAL span and never produces a 5xx response. So a breach here is a real
  5xx — treat it as one. (`service:errors:rate5m` still carries that floor; see the last section.)
- **4xx is not in here, by design.** A 401/403 storm does not burn the availability budget. That is
  `ServiceAuthFailureRateHigh` — see [service-auth-failures.md](service-auth-failures.md).

## First response
1. Identify the service from `$labels.service_name` and confirm in Grafana:
   `service:http_5xx_ratio:5m{service_name="<svc>"}` and the RED dashboard row.
2. Which endpoint, and which status?
   ```promql
   sum by (span_name, http_response_status_code) (
     rate(traces_span_metrics_calls_total{service_name="<svc>",span_kind="SPAN_KIND_SERVER",http_response_status_code=~"5.."}[30m])
   )
   ```
3. Which spans are erroring inside the request? In Explore against Tempo:
   `{resource.service.name="<svc>" && status=error}`, or click a metric exemplar to jump straight to a
   failing trace.
4. Correlate with a deploy. Check for a deploy annotation near the onset.
5. If errors localize to one endpoint, check `endpoint:errors:rate5m{service_name="<svc>"}` and read
   [endpoint-total-failure.md](endpoint-total-failure.md).

## Common causes
- A bad deploy. Correlate with annotations, then roll back.
- A downstream dependency failing. Look for the red edge on the service graph.
- Ingestion or limit issues masquerading as errors. Rule out `MimirSamplesDiscarded` before you chase
  application code.

## `ServiceAvailabilitySLIUnmeasurable`

The service serves more than 300 inbound requests per 30m and emits **no** `http.response.status_code`
on any SERVER span. So it has no availability SLI at all, and it produces NO SERIES rather than a
healthy-looking 0.

**The typical cause is a server-rendered web framework's own tracing.** Frameworks such as Next.js
emit SERVER spans (`RSC GET /auth/login`, `POST /api/auth/check-access`) that set neither
`http.response.status_code` nor `http.request.method`, and leave span status UNSET even on failure.
If the availability SLI divided by ALL SERVER spans, such a service would show a permanent,
authoritative-looking 0% error rate — a false green, and usually on your highest-traffic front end.

**THIS IS A KNOWN TRADE-OFF, NOT AN OVERSIGHT, AND THE OBVIOUS FIX IS THE WRONG ONE.** A generic
incoming-HTTP instrumentation typically has to be DISABLED on such a framework, because its duplicate
server span loses `http.route`, takes the routed span name with it, and fires an "operation on ended
Span" error once per request. Re-enabling it to recover the status code reinstates all of that, and
costs the routed span names the framework's own span still provides.

The fix is to stamp the response status onto the span that SURVIVES — a span processor or a framework
instrumentation hook setting `http.response.status_code` on the active server span. That is an
application or shared-package change. No alert rule here can substitute for it.

Until then, the only error signal for such a service is `service:errors:rate5m` — raw span-status
errors across all span kinds. It carries the benign floor and it counts internal spans, so read it as
a lead to investigate in Tempo, never as a breach.

**Whoever silences this alert is choosing to fly that service blind, and should have to say so.**

## Escalate if
A fast burn persists more than 15m after a rollback, or the error source is an external dependency.
