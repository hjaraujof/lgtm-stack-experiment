# OTel Collector Reliability and Performance

**Last Updated:** 2025-01-28
**Source:** OpenTelemetry Official Documentation + Production Best Practices

---

## Overview

Production-grade observability requires resilient telemetry pipelines. This document covers patterns for preventing data loss, handling backpressure, and optimizing performance.

---

## Resilience Mechanisms

### 1. Memory Limiter (Backpressure)

The first line of defense against OOM crashes.

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25
```

**How It Works**:
1. Monitors process memory usage
2. When soft limit exceeded: refuses new data with retryable errors
3. Receivers apply backpressure to upstream sources
4. When memory drops: resumes accepting data

**Environment Variable**:
```bash
# Set Go runtime memory limit (80% of container limit)
GOMEMLIMIT=3200MiB  # For 4GB container
```

---

### 2. Sending Queue (In-Memory Buffer)

Buffers data when backends are temporarily unavailable.

```yaml
exporters:
  otlphttp/backend:
    endpoint: http://backend:4318
    sending_queue:
      enabled: true
      num_consumers: 10              # Parallel senders
      queue_size: 1000               # Max batches buffered
      # block_on_overflow: false     # Drop vs block when full
```

**Queue Size Calculation**:
```
queue_size = buffer_seconds * requests_per_second / batch_size
```

Example: Buffer 2 minutes of 1000 spans/sec with batch size 8192:
```
queue_size = 120 * 1000 / 8192 ≈ 15 batches (round up to 100 for safety)
```

---

### 3. Retry on Failure (Exponential Backoff)

Handles transient failures gracefully.

```yaml
exporters:
  otlphttp/backend:
    endpoint: http://backend:4318
    retry_on_failure:
      enabled: true
      initial_interval: 5s           # First retry delay
      max_interval: 30s              # Max retry delay
      max_elapsed_time: 300s         # Total retry duration (0 = infinite)
      multiplier: 1.5                # Backoff multiplier
```

**Retry Sequence** (with defaults):
1. Immediate failure
2. Wait 5s, retry
3. Wait 7.5s (5 * 1.5), retry
4. Wait 11.25s, retry
5. ... continues until max_interval (30s)
6. Stops after max_elapsed_time (300s)

---

### 4. Persistent Queue (WAL)

Survives collector restarts and crashes.

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
      storage: file_storage          # Enable WAL
      queue_size: 10000              # Can be larger with disk

service:
  extensions: [file_storage]
```

**When to Use**:
- Critical data that cannot be lost
- Gateway collectors
- Long backend outages expected
- Kubernetes pod restarts

**Trade-offs**:
- Adds disk I/O overhead
- Requires persistent volume
- Slower than memory queue

---

## Data Loss Scenarios

| Scenario | Cause | Prevention |
|----------|-------|------------|
| OOM crash | No memory limiter | Enable memory_limiter as first processor |
| Queue overflow | Backend down too long | Increase queue_size, enable persistent queue |
| Retry timeout | Backend unreachable | Increase max_elapsed_time, add persistent queue |
| Collector restart | Pod killed | Enable persistent queue (WAL) |
| Disk full | WAL grows unbounded | Set queue_size limit, monitor disk |
| Network partition | Connectivity lost | Use Agent+Gateway pattern, local buffering |

---

## Performance Optimization

### Batch Processor Tuning

```yaml
processors:
  batch:
    send_batch_size: 8192            # Trigger threshold
    send_batch_max_size: 0           # 0 = no limit
    timeout: 200ms                   # Force send after timeout
```

| Profile | send_batch_size | timeout | Use Case |
|---------|-----------------|---------|----------|
| Low latency | 1024 | 100ms | Real-time alerting |
| Balanced | 8192 | 200ms | General purpose |
| High throughput | 16384 | 500ms | Batch processing |
| Maximum efficiency | 32768 | 1s | Cost optimization |

---

### Compression

```yaml
exporters:
  otlphttp/backend:
    compression: gzip                # or zstd, snappy
```

| Algorithm | CPU Cost | Compression | Best For |
|-----------|----------|-------------|----------|
| none | None | 1:1 | LAN, localhost |
| snappy | Low | ~50% | Low latency |
| gzip | Medium | ~70% | General use |
| zstd | Medium | ~75% | High throughput |

---

### Connection Pooling

```yaml
exporters:
  otlphttp/backend:
    endpoint: http://backend:4318
    sending_queue:
      num_consumers: 10              # Parallel connections
```

**Guidelines**:
- Start with 10 consumers
- Increase if `queue_size` growing but backend not saturated
- Monitor `otelcol_exporter_queue_size`

---

## Monitoring the Collector

### Essential Metrics

Enable self-telemetry:

```yaml
service:
  telemetry:
    metrics:
      level: detailed
      address: 0.0.0.0:8888
```

### Key Metrics Dashboard

| Metric | Description | Alert Condition |
|--------|-------------|-----------------|
| `otelcol_process_uptime` | Collector uptime | Restarts |
| `otelcol_process_memory_rss` | Memory usage | > 80% limit |
| `otelcol_receiver_accepted_spans` | Ingress rate | Baseline deviation |
| `otelcol_receiver_refused_spans` | Backpressure events | > 0 sustained |
| `otelcol_exporter_queue_size` | Queue depth | > 60% capacity |
| `otelcol_exporter_send_failed_spans` | Export failures | > 0 sustained |
| `otelcol_processor_batch_batch_send_size` | Actual batch sizes | Tuning insight |

### When to Scale

**Scale UP when**:
- `otelcol_receiver_refused_*` consistently > 0
- `otelcol_exporter_queue_size` > 60% capacity
- CPU utilization > 80%
- Memory approaching limits

**DON'T scale when**:
- `otelcol_exporter_send_failed_*` high (backend is bottleneck)
- Network saturation (infrastructure issue)

---

## Health Checks

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health
    check_collector_pipeline:
      enabled: true
      interval: 5m
      exporter_failure_threshold: 5

service:
  extensions: [health_check]
```

### Kubernetes Probes

```yaml
# Kubernetes deployment
livenessProbe:
  httpGet:
    path: /health
    port: 13133
  initialDelaySeconds: 15
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /health
    port: 13133
  initialDelaySeconds: 5
  periodSeconds: 5
```

---

## Sampling Strategies

### Head-Based Sampling (Simple)

Drop data at collection time:

```yaml
processors:
  probabilistic_sampler:
    hash_seed: 22
    sampling_percentage: 10          # Keep 10% of traces
```

**Pros**: Simple, predictable resource usage
**Cons**: May lose interesting traces (errors, slow)

### Tail-Based Sampling (Intelligent)

Make sampling decisions after seeing complete trace:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s               # Wait for trace completion
    num_traces: 100000               # Max traces in memory
    policies:
      - name: errors
        type: status_code
        status_code:
          status_codes: [ERROR]      # Keep all errors
      - name: slow
        type: latency
        latency:
          threshold_ms: 1000         # Keep slow traces
      - name: default
        type: probabilistic
        probabilistic:
          sampling_percentage: 5     # Sample rest at 5%
```

**Pros**: Keeps important traces (errors, slow)
**Cons**: Requires stateful processing, memory-intensive

---

## Production Configuration Template

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

  filter/healthchecks:
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["http.route"] == "/healthz"'

exporters:
  otlphttp/tempo:
    endpoint: http://tempo:4318
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

  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "demo"
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 2000

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health

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
      processors: [memory_limiter, resource, filter/healthchecks, batch]
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

## Current LGTM Stack Assessment

### Reliability Gaps

| Component | Status | Risk |
|-----------|--------|------|
| Memory limiter | Configured | Low |
| Batch processor | Configured | Low |
| Retry config | **Missing** | Medium - transient failures cause data loss |
| Sending queue | **Missing** | High - no buffering during outages |
| Persistent queue | **Missing** | Medium - data lost on restart |
| Health check | **Missing** | Medium - no Kubernetes probe support |
| Self-telemetry | **Missing** | Medium - no visibility into collector health |

### Performance Assessment

| Setting | Current | Recommended | Impact |
|---------|---------|-------------|--------|
| batch.send_batch_size | 1024 | 8192 | More efficient batching |
| batch.timeout | 1s | 200ms | Lower latency |
| Compression | None | gzip | Lower bandwidth |

### Priority Fixes

1. **Critical**: Add `otlphttp/loki` exporter (logs pipeline broken)
2. **High**: Add retry_on_failure to all exporters
3. **High**: Add sending_queue to all exporters
4. **Medium**: Add health_check extension
5. **Medium**: Enable self-telemetry metrics
6. **Low**: Add filter processor for health checks

---

## References

- [Resiliency Guide](https://opentelemetry.io/docs/collector/resiliency/)
- [Performance Tuning](https://opentelemetry.io/docs/collector/performance/)
- [Internal Telemetry](https://opentelemetry.io/docs/collector/internal-telemetry/)
- [Health Check Extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/healthcheckextension)
- [Tail Sampling Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor)
