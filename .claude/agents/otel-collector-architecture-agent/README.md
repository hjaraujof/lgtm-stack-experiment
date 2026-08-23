# OpenTelemetry Collector Architecture Agent

## Purpose

Research specialist focused on OpenTelemetry Collector pipeline configuration, receivers, processors, and exporters for the LGTM observability stack.

## Documentation

### Reference Documentation (docs/)

Comprehensive reference materials based on OpenTelemetry official documentation and production best practices:

| Document | Description |
|----------|-------------|
| [01-receivers-reference.md](docs/01-receivers-reference.md) | OTLP, Prometheus, host metrics receiver configurations |
| [02-processors-reference.md](docs/02-processors-reference.md) | Memory limiter, batch, filter, transform processors |
| [03-exporters-reference.md](docs/03-exporters-reference.md) | OTLP HTTP, Prometheus Remote Write, Loki OTLP integration |
| [04-pipeline-architecture.md](docs/04-pipeline-architecture.md) | Pipeline patterns, deployment models, connectors |
| [05-reliability-performance.md](docs/05-reliability-performance.md) | Retry, queues, sampling, monitoring the collector |
| [06-quick-reference.md](docs/06-quick-reference.md) | Cheat sheet for common patterns and configurations |

### Research Outputs (docs/)
- Contains research findings as agent is used
- Naming convention: `{topic}-{YYYY-MM-DD}.md`
- Examples: `pipeline-optimization-2025-01-15.md`, `retention-config-2025-01-20.md`

### Task Plans (tasks/)
- PRDs and implementation plans based on research findings
- Used by main Claude Code for implementation work

### Standard Procedures (sops/)
- How-to guides for common OTel Collector tasks
- Troubleshooting procedures
- Configuration templates

## Current Stack Analysis

### Critical Issue: Logs Pipeline

The current configuration uses `debug` exporter for logs instead of sending to Loki. This needs to be fixed by:

1. Adding `otlphttp/loki` exporter pointing to `http://loki:3100/otlp`
2. Enabling `allow_structured_metadata: true` in Loki config
3. Updating the logs pipeline to use the new exporter

See [03-exporters-reference.md](docs/03-exporters-reference.md) for complete fix.

### Missing Production Configurations

| Feature | Status | Document |
|---------|--------|----------|
| Retry on failure | Missing | [03-exporters-reference.md](docs/03-exporters-reference.md) |
| Sending queues | Missing | [05-reliability-performance.md](docs/05-reliability-performance.md) |
| Health check extension | Missing | [05-reliability-performance.md](docs/05-reliability-performance.md) |
| Self-telemetry | Missing | [05-reliability-performance.md](docs/05-reliability-performance.md) |
| Filter for health checks | Missing | [02-processors-reference.md](docs/02-processors-reference.md) |

## Usage

Invoke this agent when you need to research:

- **Pipeline Configuration** - Receivers, processors, exporters setup and optimization
- **Performance Tuning** - Batch sizes, memory limits, queue configuration
- **Reliability Patterns** - Retry strategies, backpressure handling, HA configuration
- **Backend Integration** - Loki, Tempo, Mimir compatibility and configuration
- **Troubleshooting** - Diagnosing data flow issues, missing telemetry, errors

## Example Invocations

```
Research how to configure tail-based sampling in OTel Collector for our Tempo integration

Analyze our current otel-collector-config.yaml and identify optimization opportunities

What processors should we add to improve trace reliability and reduce dropped spans?

How should we configure memory limits and batch sizes for production use?

What's the recommended way to send logs to Loki using OTLP?
```

## Key Configuration Files

| File | Purpose |
|------|---------|
| `config/otel-collector-config.yaml` | Main collector configuration |
| `config/tempo-config.yaml` | Tempo backend for traces |
| `config/loki-config.yaml` | Loki backend for logs |
| `config/mimir-config.yaml` | Mimir backend for metrics |

## Research Areas

1. **Receivers** - OTLP gRPC/HTTP, protocol options, TLS
2. **Processors** - Batch, memory_limiter, resource, filter, tail_sampling
3. **Exporters** - OTLP HTTP (Tempo, Loki), Prometheus Remote Write (Mimir)
4. **Service Pipelines** - Traces, metrics, logs pipeline optimization
5. **Reliability** - Queues, retries, persistent storage, health checks
6. **Observability** - Self-monitoring, metrics, alerting

## Key Findings Summary

### Loki Exporter Deprecation

The `lokiexporter` is **deprecated**. Use `otlphttp` exporter to Loki's native OTLP endpoint:

```yaml
exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp
```

### Processor Order

Always follow this order:
1. `memory_limiter` (FIRST - backpressure)
2. Resource detection/enrichment
3. Filtering/sampling
4. `batch` (LAST - before exporters)

### Essential Monitoring Metrics

| Metric | Alert When |
|--------|------------|
| `otelcol_receiver_refused_spans` | > 0 sustained |
| `otelcol_exporter_queue_size` | > 60% capacity |
| `otelcol_exporter_send_failed_spans` | > 0 sustained |

## References

- [OTel Collector Docs](https://opentelemetry.io/docs/collector/)
- [Grafana LGTM Stack](https://grafana.com/docs/opentelemetry/)
- [Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Loki OTLP Ingestion](https://grafana.com/docs/loki/latest/send-data/otel/)
- [Collector Resiliency](https://opentelemetry.io/docs/collector/resiliency/)
