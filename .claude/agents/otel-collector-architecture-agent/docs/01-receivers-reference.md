# OTel Collector Receivers Reference

**Last Updated:** 2025-01-28
**Source:** OpenTelemetry Official Documentation + Grafana LGTM Stack Best Practices

---

## Overview

Receivers are the entry point for telemetry data into the OpenTelemetry Collector. They collect data from sources using either pull or push mechanisms.

---

## OTLP Receiver (Primary)

The OTLP receiver is the standard receiver for OpenTelemetry-instrumented applications.

### Configuration Options

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317           # Default gRPC port
        max_recv_msg_size_mib: 4         # Max message size (default 4MB)
        max_concurrent_streams: 100      # gRPC stream limit
        read_buffer_size: 524288         # 512KB read buffer
        write_buffer_size: 524288        # 512KB write buffer
        keepalive:
          server_parameters:
            time: 30s                    # Ping interval
            timeout: 5s                  # Ping timeout
        tls:                             # Optional TLS config
          cert_file: /path/to/cert.pem
          key_file: /path/to/key.pem
          ca_file: /path/to/ca.pem       # For mTLS
      http:
        endpoint: 0.0.0.0:4318           # Default HTTP port
        cors:
          allowed_origins: ["*"]         # CORS settings
          allowed_headers: ["*"]
        tls:                             # Optional TLS config
          cert_file: /path/to/cert.pem
          key_file: /path/to/key.pem
```

### Best Practices

1. **Security**: Default binding is `0.0.0.0` but should be `localhost` for local-only clients
2. **gRPC vs HTTP**:
   - gRPC: Better performance, bidirectional streaming, requires HTTP/2
   - HTTP: Better firewall compatibility, easier debugging
3. **TLS**: Always enable in production; use mTLS for service-to-service auth
4. **Message Size**: Increase `max_recv_msg_size_mib` for large batch sizes

### Protocol Selection

| Use Case | Recommended Protocol |
|----------|---------------------|
| High-throughput production | gRPC |
| Browser/Edge clients | HTTP |
| Behind L4 load balancer | HTTP |
| Behind L7 load balancer | Either |
| Development/debugging | HTTP |

---

## Prometheus Receiver (Metrics Scraping)

For scraping Prometheus-compatible endpoints.

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector'
          scrape_interval: 15s
          static_configs:
            - targets: ['localhost:8888']  # Collector's own metrics
        - job_name: 'application'
          scrape_interval: 30s
          static_configs:
            - targets: ['app:9090']
```

### Scaling Considerations

- **Problem**: Multiple collectors scraping same targets = duplicate data
- **Solution**: Use Target Allocator (Kubernetes) or per-collector sharding
- **Alternative**: Use OTLP push model instead

---

## Host Metrics Receiver

For collecting host-level metrics (CPU, memory, disk, network).

```yaml
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      disk:
      filesystem:
      network:
      process:
        mute_process_name_error: true
```

---

## File Log Receiver

For collecting logs from files.

```yaml
receivers:
  filelog:
    include:
      - /var/log/*.log
      - /var/log/**/*.log
    exclude:
      - /var/log/syslog
    start_at: end                        # 'beginning' or 'end'
    include_file_name: true
    include_file_path: true
    operators:
      - type: regex_parser
        regex: '^(?P<time>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z)\s+(?P<level>\w+)\s+(?P<msg>.*)$'
        timestamp:
          parse_from: attributes.time
          layout: '%Y-%m-%dT%H:%M:%S.%LZ'
        severity:
          parse_from: attributes.level
```

---

## Receiver Health & Monitoring

### Key Metrics to Monitor

| Metric | Description | Action Threshold |
|--------|-------------|------------------|
| `otelcol_receiver_accepted_spans` | Spans successfully received | Baseline monitoring |
| `otelcol_receiver_refused_spans` | Spans rejected (backpressure) | > 0 sustained |
| `otelcol_receiver_accepted_metric_points` | Metrics received | Baseline monitoring |
| `otelcol_receiver_refused_metric_points` | Metrics rejected | > 0 sustained |
| `otelcol_receiver_accepted_log_records` | Logs received | Baseline monitoring |
| `otelcol_receiver_refused_log_records` | Logs rejected | > 0 sustained |

### Refused Data Indicates

- Memory limiter engaged (backpressure working correctly)
- Collector overloaded (need to scale)
- Pipeline bottleneck (check processors/exporters)

---

## Component Naming Convention

Multiple instances of same receiver type:

```yaml
receivers:
  otlp:                    # Default instance
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
  otlp/secure:             # Named instance
    protocols:
      grpc:
        endpoint: 0.0.0.0:4319
        tls:
          cert_file: /certs/server.crt
          key_file: /certs/server.key
```

---

## Current LGTM Stack Configuration

```yaml
# From config/otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
```

### Assessment

- **Status**: Basic but functional
- **Missing**: TLS configuration, health check endpoints
- **Recommendation**: Add health check extension for production readiness

---

## References

- [OTLP Receiver](https://github.com/open-telemetry/opentelemetry-collector/tree/main/receiver/otlpreceiver)
- [Prometheus Receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/prometheusreceiver)
- [Host Metrics Receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/hostmetricsreceiver)
- [File Log Receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver)