# Runbook: service telemetry silent

**Alert:** `ServiceTelemetrySilent` — a service that was emitting more than 0.2 req/s an hour ago has
produced no spans for 15m (warning).

Per-service, and deliberately distinct from the whole-pipeline `SpanMetricsPipelineSilent`.

## What it means
ONE service went dark while the others keep reporting. Usually a broken deploy, a crash loop, an
endpoint rename, or instrumentation being disabled. It is normally NOT a stack problem: if the stack
were down, `SpanMetricsPipelineSilent` would fire and INHIBIT this alert.

## First response
1. Is the service actually running? Check its own health and deploy status on its own platform. This
   alert is about the SERVICE, not about the LGTM stack.
2. Did a recent deploy remove or replace the OTel SDK initialization, or change `OTEL_SERVICE_NAME`?
   A renamed service reads as "absent" here and as "new" everywhere else. Check for a new
   `service_name` appearing at about the same time the old one vanished.
3. Confirm ingress reachability: does the service's `OTEL_EXPORTER_OTLP_ENDPOINT` still resolve and
   route?
4. Rule out a false positive: `sum(rate(traces_span_metrics_calls_total[5m]))` should be >0 for other
   services.

## Why the alert has a traffic gate
The naive form of this rule keys on series PRESENCE an hour ago rather than on traffic. A naturally
sparse or intermittent service then false-fires "stopped emitting" on every idle hour, and the alert
gets ignored inside a week. The gate at >0.2 req/s means only a service that was GENUINELY reporting
and then went silent can alert.

## Common causes
- A deploy broke instrumentation, or changed the service name.
- Service crash loop, or scaled to zero.
- A network or endpoint change.
