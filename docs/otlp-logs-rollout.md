# Enabling OTLP logs for your services

## Symptom

Traces and metrics flow into Tempo and Mimir, but Loki shows zero application
logs for every service (only test-script log entries appear). The Loki / OTel
Collector pipeline is healthy end-to-end — verified by sending an OTLP log
payload directly to both the collector (`HTTP 200`) and Loki
(`HTTP 204 → loki_distributor_lines_received_total` increments).

## Root cause — client-side env config

A typical Node app uses two packages:

| Package | Purpose | Env var that activates it |
|---|---|---|
| An OTel Node SDK init wrapper | Traces | Often a **custom** endpoint variable, not a standard one |
| A Pino-based logger wrapper | Logs | `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` **or** `OTEL_EXPORTER_OTLP_ENDPOINT` (standard OTel) |

This asymmetry is the trap, and it is common. A house tracing wrapper is often
wired to its own endpoint variable, while the logging wrapper reads only the
standard OTel names. Setting the tracing one therefore makes traces flow and
leaves logs silently disabled. Check what your own wrapper reads before you
assume one variable covers both.

A Pino wrapper typically registers a `pino-opentelemetry-transport` target only
when one of the standard vars is set, in the code that builds its transport
targets:

```ts
const hasOtlpEndpoint = !!(
    process.env.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT ||
    process.env.OTEL_EXPORTER_OTLP_ENDPOINT
);
if (hasOtlpEndpoint) {
    targets.push({ target: 'pino-opentelemetry-transport', ... });
}
```

If a service sets only the tracing wrapper's own endpoint variable, and not the
standard OTel logs or generic endpoint, the logger omits the OTLP transport
without warning. Logs then reach CloudWatch, a file or the console only — never
Loki. Nothing errors, which is why this survives a deployment unnoticed.

## Fix

Add one of these env vars to each service's deployment environment (ECS task
definition, k8s manifest, CI/CD deploy step, etc.):

```bash
# Logs-only:
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://otel-collector.internal.example.com:4318

# Or generic — covers logs and any future signals:
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.internal.example.com:4318
```

The OTel HTTP exporter appends `/v1/logs` automatically. Your service needs no
tenant header: it sends to the collector, and the collector stamps
`X-Scope-OrgID: demo` on the push to Loki
(`config/otel-collector-config.yaml`, exporter `otlphttp/loki`).

Loki runs multi-tenant here, so any client that talks to Loki **directly** must
send that header. Tenant `fake` is the tenant Loki falls back to when a push
carries no header, and it is an error state on this stack — the
`LokiTenantFakeIngest` alert fires on it. See `docs/runbooks/loki-discards.md`.

For local development, swap the host for `http://localhost:4318`.

## Verification after rollout

```bash
# On the EC2 host (or via SSM):
# /metrics is an admin endpoint and stays tenant-free.
curl -s http://localhost:3100/metrics | grep loki_distributor_lines_received_total
# Should be increasing.

# Query endpoints are tenant-scoped. Without the header this returns the empty
# `fake` tenant, which looks identical to "the rollout did not work".
curl -s -H 'X-Scope-OrgID: demo' \
  http://localhost:3100/loki/api/v1/label/service_name/values
# Should list the rolled-out services.
```

In Grafana Explore, query `{service_name="<tenant>/<env>/<service>"}` on the
Loki datasource — traces in Tempo and logs in Loki should now correlate via
the `traceID` derived field already configured in
`config/grafana/provisioning/datasources/datasources.yaml`.
