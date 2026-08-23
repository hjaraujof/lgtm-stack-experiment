# OTel Collector Quick Reference

**Last Updated:** 2025-01-28

A cheat sheet for common OpenTelemetry Collector patterns and configurations.

---

## Essential Configuration Snippets

### Minimal Production-Ready OTLP Receiver

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
```

### Memory Limiter (Always First)

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25
```

### Batch Processor (Always Last)

```yaml
processors:
  batch:
    send_batch_size: 8192
    timeout: 200ms
```

### Health Check Extension

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health

service:
  extensions: [health_check]
```

---

## LGTM Stack Exporters

### Tempo (Traces)

```yaml
exporters:
  otlphttp/tempo:
    endpoint: http://tempo:4318
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 1000
```

### Loki (Logs) - Use OTLP, NOT lokiexporter

```yaml
exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 1000
```

**Loki requirement** (in loki-config.yaml):
```yaml
limits_config:
  allow_structured_metadata: true
```

### Mimir (Metrics)

```yaml
exporters:
  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "demo"
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 2000
```

---

## Common Processors

### Filter Health Checks from Traces

```yaml
processors:
  filter/healthchecks:
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["http.route"] == "/healthz"'
        - 'attributes["http.route"] == "/ready"'
```

### Add Environment Attribute

```yaml
processors:
  resource:
    attributes:
      - key: deployment.environment
        value: ${env:AP_ENVIRONMENT:-development}
        action: upsert
```

### Remove Sensitive Data

```yaml
processors:
  attributes:
    actions:
      - key: http.request.header.authorization
        action: delete
      - key: db.statement
        action: hash
```

---

## Processor Order

```yaml
service:
  pipelines:
    traces:
      processors:
        - memory_limiter    # 1. FIRST - backpressure
        - resourcedetection # 2. Infrastructure metadata
        - resource          # 3. Add/modify attributes
        - filter            # 4. Drop unwanted data
        - batch             # 5. LAST - batching
```

---

## Retry and Queue Settings

### Default Retry (Good Starting Point)

```yaml
retry_on_failure:
  enabled: true
  initial_interval: 5s
  max_interval: 30s
  max_elapsed_time: 300s
```

### Aggressive Retry (Critical Data)

```yaml
retry_on_failure:
  enabled: true
  initial_interval: 1s
  max_interval: 60s
  max_elapsed_time: 0      # Never give up
```

### Queue Sizing Formula

```
queue_size = buffer_seconds * requests_per_second / batch_size
```

---

## Self-Monitoring

### Enable Prometheus Metrics

```yaml
service:
  telemetry:
    metrics:
      level: detailed
      address: 0.0.0.0:8888
```

### Key Metrics to Monitor

| Metric | Alert Condition |
|--------|-----------------|
| `otelcol_receiver_refused_spans` | > 0 sustained |
| `otelcol_exporter_queue_size` | > 60% capacity |
| `otelcol_exporter_send_failed_spans` | > 0 sustained |
| `otelcol_process_memory_rss` | > 80% limit |

---

## Environment Variables

```bash
# Go runtime memory limit
GOMEMLIMIT=3200MiB

# OTLP exporter settings (for applications)
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=my-service
```

---

## Debugging

### Debug Exporter (Dev Only)

```yaml
exporters:
  debug:
    verbosity: detailed
```

### Check Collector Health

```bash
curl http://localhost:13133/health

# Prometheus metrics
curl http://localhost:8888/metrics
```

### Validate Configuration

```bash
otelcol validate --config=config.yaml
```

---

## Complete LGTM Pipeline Template

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25
  batch:
    send_batch_size: 8192
    timeout: 200ms
  resource:
    attributes:
      - key: deployment.environment
        value: ${env:AP_ENVIRONMENT:-development}
        action: upsert

exporters:
  otlphttp/tempo:
    endpoint: http://tempo:4318
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true

  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true

  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "demo"
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
  telemetry:
    logs:
      level: info
    metrics:
      level: detailed
      address: 0.0.0.0:8888
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlphttp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [prometheusremotewrite/mimir]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [otlphttp/loki]
```

---

## Common Mistakes to Avoid

| Mistake | Fix |
|---------|-----|
| Missing memory_limiter | Always add as FIRST processor |
| Using lokiexporter | Use otlphttp to /otlp endpoint |
| No retry config | Add retry_on_failure to all network exporters |
| No queues | Add sending_queue to all network exporters |
| batch before memory_limiter | memory_limiter FIRST, batch LAST |
| No health check | Add health_check extension for K8s probes |

---

## Port Reference

| Port | Service | Protocol |
|------|---------|----------|
| 4317 | OTLP gRPC receiver | gRPC |
| 4318 | OTLP HTTP receiver | HTTP |
| 8888 | Collector metrics | HTTP (Prometheus) |
| 13133 | Health check | HTTP |
| 3100 | Loki | HTTP |
| 3200 | Tempo | HTTP |
| 9009 | Mimir | HTTP |
| 3000 | Grafana | HTTP |
