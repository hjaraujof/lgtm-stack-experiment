# OTel Collector Pipeline Architecture

**Last Updated:** 2025-01-28
**Source:** OpenTelemetry Official Documentation + Production Best Practices

---

## Overview

Pipelines define how telemetry data flows through the collector: from receivers, through processors, to exporters. Understanding pipeline architecture is essential for building efficient, reliable observability systems.

---

## Pipeline Fundamentals

### Signal Types

OpenTelemetry defines three signal types, each requiring separate pipelines:

| Signal | Description | Common Sources |
|--------|-------------|----------------|
| **traces** | Distributed traces (spans) | Application instrumentation |
| **metrics** | Time-series metrics | Prometheus, host metrics, app metrics |
| **logs** | Log records | Application logs, system logs |

### Pipeline Structure

```yaml
service:
  pipelines:
    <signal_type>:
      receivers: [receiver1, receiver2]
      processors: [processor1, processor2]
      exporters: [exporter1, exporter2]
```

**Key Rules**:
1. Each signal type can have multiple pipelines (named with `/<suffix>`)
2. Components can be shared across pipelines
3. Processors create separate instances per pipeline
4. Order of processors matters (executed sequentially)

---

## Deployment Patterns

### Pattern 1: No Collector (Direct Export)

```
Application ──OTLP──> Backend
```

**Use Cases**:
- Simple deployments
- Serverless functions
- Development environments

**Pros**: Simple, no extra infrastructure
**Cons**: No buffering, no transformation, no multi-backend fanout

---

### Pattern 2: Agent Pattern (Sidecar/DaemonSet)

```
Application ──OTLP──> Collector Agent ──> Backend
                      (per-node/per-pod)
```

**Use Cases**:
- Kubernetes deployments
- Containerized applications
- Host-level metric collection

**Configuration Focus**:
- Lightweight resource limits
- Local buffering
- Minimal processing

```yaml
# Agent configuration example
processors:
  memory_limiter:
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    send_batch_size: 1024
    timeout: 100ms
```

---

### Pattern 3: Gateway Pattern (Centralized)

```
Application ──OTLP──> Collector Gateway ──> Backend
                      (centralized cluster)
```

**Use Cases**:
- Multi-tenant environments
- Complex processing requirements
- Cost optimization (sampling, filtering)

**Configuration Focus**:
- Higher resource allocation
- Persistent queues
- Advanced processing

---

### Pattern 4: Agent + Gateway (Tiered)

```
                         ┌──> Backend A (Traces)
Application ──> Agent ──>│──> Backend B (Metrics)
                Gateway  └──> Backend C (Logs)
```

**Use Cases**:
- Enterprise deployments
- Multi-backend requirements
- Maximum resilience

**Benefits**:
- Local buffering (Agent)
- Central processing (Gateway)
- Backend isolation
- Independent scaling

---

## Multi-Pipeline Configurations

### Separate Processing per Signal

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, filter/traces, batch]
      exporters: [otlphttp/tempo]

    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, filter/metrics, batch]
      exporters: [prometheusremotewrite/mimir]

    logs:
      receivers: [otlp]
      processors: [memory_limiter, filter/logs, batch]
      exporters: [otlphttp/loki]
```

### Multi-Destination Fanout

Send same data to multiple backends:

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/tempo, otlphttp/jaeger, debug]
```

### Separate Pipelines for Different Sources

```yaml
service:
  pipelines:
    # Application traces
    traces/app:
      receivers: [otlp]
      processors: [memory_limiter, resource/app, batch]
      exporters: [otlphttp/tempo]

    # Infrastructure traces
    traces/infra:
      receivers: [jaeger]
      processors: [memory_limiter, resource/infra, batch]
      exporters: [otlphttp/tempo]
```

---

## Connectors

Connectors join pipelines, acting as both exporter and receiver.

### Span-to-Metrics Connector

Generate metrics from trace data:

```yaml
connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [10ms, 50ms, 100ms, 500ms, 1s, 5s]
    dimensions:
      - name: http.method
      - name: http.status_code
    exemplars:
      enabled: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/tempo, spanmetrics]  # Fan out to connector

    metrics/spanmetrics:
      receivers: [spanmetrics]  # Connector as receiver
      processors: [batch]
      exporters: [prometheusremotewrite/mimir]
```

### Count Connector

Count telemetry items:

```yaml
connectors:
  count:
    traces:
      trace.count:
        description: "Count of traces"
    spans:
      span.count:
        description: "Count of spans"
        conditions:
          - 'attributes["http.status_code"] >= 400'

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [count, otlphttp/tempo]

    metrics/counts:
      receivers: [count]
      exporters: [prometheusremotewrite/mimir]
```

---

## Pipeline for LGTM Stack

### Recommended Architecture

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
        - 'attributes["http.target"] == "/healthz"'
        - 'attributes["http.target"] == "/ready"'

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

  otlphttp/loki:
    endpoint: http://loki:3100/otlp
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
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

service:
  telemetry:
    logs:
      level: info
    metrics:
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

## Service Configuration

### Telemetry (Self-Monitoring)

```yaml
service:
  telemetry:
    logs:
      level: info                    # debug, info, warn, error
      encoding: json                 # json, console
      output_paths: ["stderr"]
    metrics:
      level: detailed                # none, basic, normal, detailed
      address: 0.0.0.0:8888          # Prometheus endpoint
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
    traces:
      processors:
        - batch:
            exporter:
              otlp:
                protocol: grpc/protobuf
                endpoint: tempo:4317
```

### Extensions

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
    path: /health

  pprof:
    endpoint: 0.0.0.0:1777

  zpages:
    endpoint: 0.0.0.0:55679

service:
  extensions: [health_check, pprof, zpages]
```

---

## Data Flow Visualization

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                    OTel Collector                        │
                    │                                                          │
    Applications    │  ┌──────────┐    ┌────────────┐    ┌──────────────────┐ │
         │          │  │          │    │            │    │                  │ │
    OTLP │          │  │ Receivers│───>│ Processors │───>│    Exporters     │ │
    gRPC ├─────────>│  │  (OTLP)  │    │ (mem_limit │    │ (otlphttp/tempo) │──────> Tempo
   :4317 │          │  │          │    │  resource  │    │                  │ │
         │          │  │          │    │  filter    │    │ (otlphttp/loki)  │──────> Loki
    OTLP │          │  │          │    │  batch)    │    │                  │ │
    HTTP ├─────────>│  │          │    │            │    │ (promrw/mimir)   │──────> Mimir
   :4318 │          │  └──────────┘    └────────────┘    └──────────────────┘ │
                    │                                                          │
                    │  Extensions: health_check:13133, metrics:8888            │
                    └─────────────────────────────────────────────────────────┘
```

---

## Current LGTM Stack Pipeline Analysis

### Current Configuration

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/tempo]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite/mimir]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]              # <-- PROBLEM
```

### Issues Identified

| Pipeline | Status | Issue |
|----------|--------|-------|
| traces | OK | Working, missing retry/queue |
| metrics | OK | Working, missing retry/queue |
| logs | **BROKEN** | Using debug instead of Loki exporter |

### Gaps

1. **Missing**: Health check extension
2. **Missing**: Self-telemetry metrics endpoint
3. **Missing**: Resource enrichment processor
4. **Missing**: Filter processor for health checks
5. **Missing**: Retry/queue configuration on exporters

---

## Scaling Considerations

### Horizontal Scaling

Most collector components are stateless and scale horizontally:

```
                    ┌─────────────┐
                    │ Load        │
Applications ──────>│ Balancer    │──────> Collector Pods
                    │ (L7 for     │        (N replicas)
                    │  gRPC)      │
                    └─────────────┘
```

### Stateful Components

These require consistent routing (load-balancing exporter):

- **Tail Sampling Processor**: Needs all spans from a trace
- **Span Metrics Processor**: Needs complete trace data

```yaml
# Tier 1: Load balancing layer
exporters:
  loadbalancing:
    protocol:
      otlp:
        endpoint: collector-tier2:4317
    resolver:
      dns:
        hostname: collector-tier2-headless

# Tier 2: Stateful processing
processors:
  tail_sampling:
    decision_wait: 10s
    policies: [...]
```

---

## References

- [OTel Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Deployment Patterns](https://opentelemetry.io/docs/collector/deployment/)
- [Scaling Guide](https://opentelemetry.io/docs/collector/scaling/)
- [Connectors](https://opentelemetry.io/docs/collector/configuration/#connectors)
