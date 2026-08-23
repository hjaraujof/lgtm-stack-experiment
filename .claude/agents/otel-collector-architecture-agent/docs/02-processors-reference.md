# OTel Collector Processors Reference

**Last Updated:** 2025-01-28
**Source:** OpenTelemetry Official Documentation + Production Best Practices

---

## Overview

Processors transform, filter, and enrich telemetry data between receivers and exporters. They execute in the order specified in the pipeline configuration.

**Critical Rule**: Processor order matters. Place memory_limiter FIRST, batch processor LAST (before exporters).

---

## Essential Processors

### 1. Memory Limiter Processor (REQUIRED)

Prevents out-of-memory crashes by applying backpressure when memory limits are approached.

```yaml
processors:
  memory_limiter:
    check_interval: 1s              # How often to check memory (default 0s)
    limit_percentage: 75            # Hard limit as % of total memory
    spike_limit_percentage: 25      # Buffer for spikes
    # OR use absolute values:
    # limit_mib: 4000               # Hard limit in MiB
    # spike_limit_mib: 800          # Spike allowance in MiB
```

#### Configuration Strategy

| Environment | limit_percentage | spike_limit_percentage |
|-------------|------------------|------------------------|
| Development | 75 | 25 |
| Production (containers) | 80 | 15 |
| High-traffic | 70 | 20 |

#### How It Works

- **Hard Limit**: `limit_percentage` (or `limit_mib`)
- **Soft Limit**: Hard limit - spike limit
- When soft limit exceeded: Refuses new data with retryable errors
- Receivers apply backpressure upstream

#### Best Practices

1. **Always place FIRST** in every pipeline
2. Set `GOMEMLIMIT` env var to 80% of container memory limit
3. Use percentage-based limits for dynamic environments
4. `check_interval` of 1s is recommended (default 0s means disabled)

---

### 2. Batch Processor (RECOMMENDED)

Groups telemetry into batches for efficient export.

```yaml
processors:
  batch:
    send_batch_size: 8192           # Trigger batch at this count (default 8192)
    send_batch_max_size: 0          # Max batch size, 0 = no limit
    timeout: 200ms                  # Send after this duration (default 200ms)
    # metadata_keys: []             # For multi-tenant batching
    # metadata_cardinality_limit: 1000
```

#### Configuration Strategy

| Scenario | send_batch_size | timeout | Notes |
|----------|-----------------|---------|-------|
| Low latency required | 1024 | 100ms | More network calls |
| High throughput | 10000 | 500ms | Better efficiency |
| Balanced (default) | 8192 | 200ms | Good for most cases |
| Size-constrained | 8192 | 200ms | Set send_batch_max_size |

#### Best Practices

1. **Place AFTER** memory_limiter and sampling processors
2. **Place BEFORE** exporters (typically last processor)
3. For maximum throughput with size limits: use `send_batch_max_size` with `timeout: 0s`
4. Monitor `otelcol_processor_batch_batch_send_size` for tuning

---

### 3. Resource Processor

Modifies resource-level attributes (service.name, cloud.region, etc.).

```yaml
processors:
  resource:
    attributes:
      - key: environment
        value: production
        action: insert              # insert, update, upsert, delete
      - key: cloud.region
        value: us-east-1
        action: upsert
      - key: internal.debug
        action: delete
      - key: service.namespace
        from_attribute: k8s.namespace.name
        action: insert
```

#### Actions

| Action | Behavior |
|--------|----------|
| `insert` | Add if key doesn't exist |
| `update` | Modify if key exists |
| `upsert` | Insert or update |
| `delete` | Remove attribute |

---

### 4. Attributes Processor

Modifies span/metric/log attributes (not resource attributes).

```yaml
processors:
  attributes:
    actions:
      - key: http.request.header.authorization
        action: delete              # Remove sensitive data
      - key: http.url
        action: hash                # Hash sensitive values
      - key: db.statement
        pattern: "password=.*"
        replacement: "password=***"
        action: extract
```

#### Use Cases

- Removing sensitive data (PII, credentials)
- Adding enrichment attributes
- Standardizing attribute names
- Hashing sensitive values

---

### 5. Filter Processor

Drops telemetry based on conditions (reduces volume/cost).

```yaml
processors:
  filter:
    error_mode: ignore              # ignore, propagate, silent
    traces:
      span:
        - 'attributes["http.target"] == "/health"'
        - 'attributes["http.target"] == "/ready"'
    metrics:
      metric:
        - 'name == "system.cpu.time"'
    logs:
      log_record:
        - 'severity_number < SEVERITY_NUMBER_WARN'
```

#### Common Filter Patterns

```yaml
# Drop health check traces
filter/healthchecks:
  traces:
    span:
      - 'attributes["http.route"] == "/health"'
      - 'attributes["http.route"] == "/healthz"'
      - 'attributes["http.route"] == "/ready"'
      - 'attributes["http.route"] == "/metrics"'

# Keep only errors in logs
filter/errors_only:
  logs:
    log_record:
      - 'severity_number < SEVERITY_NUMBER_ERROR'

# Drop specific service's debug spans
filter/service_debug:
  traces:
    span:
      - 'resource.attributes["service.name"] == "noisy-service" and attributes["span.kind"] == "internal"'
```

---

### 6. Transform Processor

Advanced transformations using OpenTelemetry Transformation Language (OTTL).

```yaml
processors:
  transform:
    error_mode: ignore
    trace_statements:
      - context: resource
        statements:
          - keep_keys(attributes, ["service.name", "service.namespace", "cloud.region"])
          - limit(attributes, 100, [])
          - truncate_all(attributes, 4096)
      - context: span
        statements:
          - set(status.code, 2) where attributes["http.status_code"] >= 500
          - set(name, Concat([attributes["http.method"], " ", attributes["http.route"]])) where attributes["http.route"] != nil
    metric_statements:
      - context: datapoint
        statements:
          - limit(attributes, 50, [])
    log_statements:
      - context: log
        statements:
          - set(severity_text, "ERROR") where severity_number >= 17
```

#### OTTL Functions

| Function | Description |
|----------|-------------|
| `set(target, value)` | Set attribute value |
| `delete_key(map, key)` | Remove key from map |
| `keep_keys(map, keys[])` | Keep only specified keys |
| `truncate_all(map, limit)` | Truncate all string values |
| `limit(map, limit, keys[])` | Limit number of attributes |
| `Concat(strings[])` | Concatenate strings |

---

### 7. Resource Detection Processor

Auto-detects and adds infrastructure metadata.

```yaml
processors:
  resourcedetection:
    detectors: [env, system, docker, ec2, ecs, gcp, azure]
    timeout: 5s
    override: false                 # Don't override existing attributes
    ec2:
      tags: ["Name", "Environment"]
    system:
      hostname_sources: ["os"]
```

#### Available Detectors

| Detector | Attributes Added |
|----------|-----------------|
| `env` | From OTEL_RESOURCE_ATTRIBUTES env var |
| `system` | host.name, host.arch, os.type |
| `docker` | container.id, container.name |
| `ec2` | cloud.provider, cloud.region, host.id |
| `ecs` | AWS ECS task/container metadata |
| `gcp` | GCP project, zone, instance |
| `azure` | Azure subscription, resource group |

---

### 8. K8s Attributes Processor

Enriches telemetry with Kubernetes metadata.

```yaml
processors:
  k8sattributes:
    auth_type: "serviceAccount"
    passthrough: false
    extract:
      metadata:
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.namespace.name
        - k8s.node.name
        - k8s.deployment.name
      labels:
        - tag_name: app
          key: app.kubernetes.io/name
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip
```

---

## Processor Order Recommendation

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors:
        - memory_limiter    # 1. Always first - backpressure
        - resourcedetection # 2. Add infrastructure context
        - k8sattributes     # 3. Add K8s context (if applicable)
        - resource          # 4. Modify resource attributes
        - attributes        # 5. Modify span/log attributes
        - filter            # 6. Drop unwanted data
        - transform         # 7. Complex transformations
        - batch             # 8. Always last - batching
      exporters: [otlphttp/tempo]
```

---

## Current LGTM Stack Configuration

```yaml
# From config/otel-collector-config.yaml
processors:
  batch:
    send_batch_size: 1024
    timeout: 1s
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25
```

### Assessment

- **Status**: Good basic configuration
- **Correct**: memory_limiter configured with percentages
- **Correct**: batch processor with reasonable settings
- **Missing**: Resource detection, attribute enrichment, filtering
- **Note**: Pipeline order has memory_limiter first (correct)

### Recommendations

1. Consider adding `filter` processor for health check endpoints
2. Add `resource` processor for environment tagging
3. Consider `resourcedetection` for cloud metadata

---

## Monitoring Processors

| Metric | Description |
|--------|-------------|
| `otelcol_processor_batch_batch_send_size` | Actual batch sizes sent |
| `otelcol_processor_batch_timeout_trigger_send` | Batches sent due to timeout |
| `otelcol_processor_filter_spans_filtered` | Spans dropped by filter |
| `otelcol_processor_filter_metrics_filtered` | Metrics dropped by filter |

---

## References

- [Batch Processor](https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/batchprocessor)
- [Memory Limiter](https://github.com/open-telemetry/opentelemetry-collector/tree/main/processor/memorylimiterprocessor)
- [Filter Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/filterprocessor)
- [Transform Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/transformprocessor)
- [Attributes Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/attributesprocessor)
- [Resource Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourceprocessor)
