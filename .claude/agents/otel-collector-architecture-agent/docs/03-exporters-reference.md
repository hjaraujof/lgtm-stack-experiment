# OTel Collector Exporters Reference

**Last Updated:** 2025-01-28
**Source:** OpenTelemetry Official Documentation + Grafana LGTM Stack Best Practices

---

## Overview

Exporters send processed telemetry data to backends or downstream systems. They are the final stage in the collector pipeline.

---

## LGTM Stack Exporters

### 1. OTLP HTTP Exporter (Traces to Tempo, Logs to Loki)

The OTLP HTTP exporter is the **recommended** exporter for sending data to Grafana Tempo and Loki.

#### For Tempo (Traces)

```yaml
exporters:
  otlphttp/tempo:
    endpoint: http://tempo:4318      # Tempo's OTLP HTTP endpoint
    tls:
      insecure: true                 # For local development
    # Production TLS:
    # tls:
    #   cert_file: /certs/client.crt
    #   key_file: /certs/client.key
    #   ca_file: /certs/ca.crt
    headers:
      X-Scope-OrgID: "demo"          # For multi-tenancy
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000
```

#### For Loki (Logs) - OTLP Native Ingestion

**IMPORTANT**: The `lokiexporter` is **DEPRECATED**. Use `otlphttp` exporter to Loki's native OTLP endpoint instead.

```yaml
exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp  # Loki's OTLP endpoint
    tls:
      insecure: true
    headers:
      X-Scope-OrgID: "demo"
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      queue_size: 1000
```

##### Loki Requirements for OTLP

**Loki Configuration** (must be set in loki-config.yaml):
```yaml
limits_config:
  allow_structured_metadata: true    # Required for OTLP ingestion
```

**Note**: `allow_structured_metadata` is enabled by default in Loki 3.0+.

##### Attribute Mapping in Loki

| OTLP Source | Loki Destination |
|-------------|------------------|
| Resource attributes (select) | Index labels |
| Resource attributes (rest) | Structured metadata |
| Log record attributes | Structured metadata |
| Instrumentation scope | Structured metadata |
| Log body | Log line |

**Default Index Labels** (17 attributes):
- `service.name`, `service.namespace`, `service.instance.id`
- `deployment.environment`, `cloud.region`, `cloud.availability_zone`
- `k8s.cluster.name`, `k8s.namespace.name`, `k8s.pod.name`
- `k8s.container.name`, `k8s.replicaset.name`, `k8s.deployment.name`
- `k8s.statefulset.name`, `k8s.daemonset.name`, `k8s.cronjob.name`
- `k8s.job.name`, `container.name`

**Cardinality Warning**: Remove high-cardinality labels like `k8s.pod.name` and `service.instance.id` from index labels in production.

---

### 2. Prometheus Remote Write Exporter (Metrics to Mimir)

```yaml
exporters:
  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "demo"          # Required for Mimir multi-tenancy
    tls:
      insecure: true
    # resource_to_telemetry_conversion:
    #   enabled: true                # Convert resource attrs to labels
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      queue_size: 2000               # Metrics can be high volume
```

#### Mimir-Specific Headers

| Header | Purpose |
|--------|---------|
| `X-Scope-OrgID` | Tenant ID for multi-tenancy |
| `X-Mimir-Exemplars-Enabled` | Enable exemplars (optional) |

---

### 3. Debug Exporter (Development Only)

For troubleshooting and development - **NOT for production**.

```yaml
exporters:
  debug:
    verbosity: detailed              # basic, normal, detailed
    sampling_initial: 5              # Log first N items
    sampling_thereafter: 200         # Then every Nth item
```

---

## Exporter Resilience Configuration

### Retry Configuration

All network exporters should have retry configured:

```yaml
exporters:
  otlphttp/example:
    endpoint: http://backend:4318
    retry_on_failure:
      enabled: true                  # default: true
      initial_interval: 5s           # default: 5s
      max_interval: 30s              # default: 30s
      max_elapsed_time: 300s         # default: 300s (5 min), 0 = infinite
      multiplier: 1.5                # default: 1.5 (exponential backoff)
```

### Sending Queue Configuration

Enable queues for all network exporters:

```yaml
exporters:
  otlphttp/example:
    endpoint: http://backend:4318
    sending_queue:
      enabled: true                  # default: true
      num_consumers: 10              # Parallel senders (default: 10)
      queue_size: 1000               # Max batches queued (default: 1000)
      # storage: file_storage        # For persistent queue (see below)
```

#### Queue Sizing Formula

```
queue_size = num_seconds * requests_per_second / requests_per_batch
```

Example: Buffer 60 seconds at 100 req/s with batch size 100:
```
queue_size = 60 * 100 / 100 = 60 batches minimum
```

### Persistent Queue (WAL)

For crash recovery, enable persistent queues:

```yaml
extensions:
  file_storage:
    directory: /var/lib/otelcol/storage
    timeout: 10s
    compaction:
      on_start: true
      directory: /var/lib/otelcol/storage
      max_transaction_size: 65_536

exporters:
  otlphttp/critical:
    endpoint: http://backend:4318
    sending_queue:
      enabled: true
      storage: file_storage          # Reference the extension
      queue_size: 10000              # Can be larger with disk backing
```

---

## Timeout Configuration

```yaml
exporters:
  otlphttp/example:
    endpoint: http://backend:4318
    timeout: 30s                     # default: 30s
```

---

## Compression

```yaml
exporters:
  otlphttp/example:
    endpoint: http://backend:4318
    compression: gzip                # none, gzip, zstd, snappy, zlib
```

| Compression | CPU | Ratio | Use Case |
|-------------|-----|-------|----------|
| none | Low | 1:1 | LAN/localhost |
| gzip | Medium | Good | General purpose |
| zstd | Medium | Better | High throughput |
| snappy | Low | OK | Low latency |

---

## Authentication

### Basic Auth

```yaml
extensions:
  basicauth/backend:
    client_auth:
      username: ${env:BACKEND_USER}
      password: ${env:BACKEND_PASS}

exporters:
  otlphttp/authenticated:
    endpoint: http://backend:4318
    auth:
      authenticator: basicauth/backend

service:
  extensions: [basicauth/backend]
  pipelines:
    traces:
      exporters: [otlphttp/authenticated]
```

### Bearer Token

```yaml
extensions:
  bearertokenauth:
    token: ${env:API_TOKEN}

exporters:
  otlphttp/authenticated:
    endpoint: http://backend:4318
    auth:
      authenticator: bearertokenauth
```

### OAuth2

```yaml
extensions:
  oauth2client:
    client_id: ${env:CLIENT_ID}
    client_secret: ${env:CLIENT_SECRET}
    token_url: https://auth.example.com/token
    scopes: ["telemetry:write"]

exporters:
  otlphttp/authenticated:
    endpoint: http://backend:4318
    auth:
      authenticator: oauth2client
```

---

## Current LGTM Stack Configuration

```yaml
# From config/otel-collector-config.yaml
exporters:
  otlphttp/tempo:
    endpoint: http://tempo:14318
    tls:
      insecure: true

  debug:
    verbosity: detailed

  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "demo"
```

### Assessment

| Component | Status | Issue |
|-----------|--------|-------|
| Traces (Tempo) | Working | Missing retry/queue config |
| Metrics (Mimir) | Working | Missing retry/queue config |
| Logs (Loki) | **BROKEN** | Using debug exporter instead of otlphttp |

### Critical Fix Required: Logs Pipeline

Replace debug exporter with proper Loki integration:

```yaml
exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      queue_size: 1000

service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/loki]
```

**Also Required**: Update `loki-config.yaml`:
```yaml
limits_config:
  allow_structured_metadata: true
```

---

## Monitoring Exporters

| Metric | Description | Alert Threshold |
|--------|-------------|-----------------|
| `otelcol_exporter_queue_size` | Current queue depth | > 60% capacity |
| `otelcol_exporter_queue_capacity` | Max queue size | Baseline |
| `otelcol_exporter_sent_spans` | Spans exported | Baseline |
| `otelcol_exporter_send_failed_spans` | Failed exports | > 0 sustained |
| `otelcol_exporter_send_failed_metric_points` | Failed metrics | > 0 sustained |
| `otelcol_exporter_send_failed_log_records` | Failed logs | > 0 sustained |

---

## Legacy Loki Exporter (DEPRECATED)

**DO NOT USE** - Included only for reference when migrating old configurations.

```yaml
# DEPRECATED - Use otlphttp/loki instead
exporters:
  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    default_labels_enabled:
      exporter: true
      job: true
```

Migration: Replace with `otlphttp` exporter pointing to `/otlp` endpoint.

---

## References

- [OTLP HTTP Exporter](https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/otlphttpexporter)
- [Prometheus Remote Write Exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusremotewriteexporter)
- [Loki OTLP Ingestion](https://grafana.com/docs/loki/latest/send-data/otel/)
- [Exporter Helper](https://github.com/open-telemetry/opentelemetry-collector/tree/main/exporter/exporterhelper)
- [File Storage Extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/storage/filestorage)
