# Metrics Exemplars Configuration

## Overview

Exemplars bridge the gap between metrics and traces by embedding trace IDs directly into metric data points. An exemplar is a specific trace that represents a measurement taken during a time interval, allowing you to drill down from aggregated metrics (showing trends) to individual traces (showing specific requests).

Exemplars solve the problem: "I see high latency in my metrics dashboard - which specific requests caused this?"

## How Exemplars Work

1. **Tempo Metrics Generator** creates metrics from spans and attaches trace IDs as exemplars
2. **Mimir/Prometheus** stores these metrics with their exemplar data
3. **Grafana** displays exemplars as clickable data points in metric visualizations
4. **Clicking an exemplar** opens the corresponding trace in Tempo

```
Application → Tempo → Metrics Generator → Mimir (with exemplars) → Grafana (clickable points)
                   ↓
               Traces stored
```

## Current Configuration

### Tempo Metrics Generator

Located in: `config/tempo-config.yaml`

```yaml
metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /tmp/tempo/generator/wal
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true
```

**Key Configuration:**

- `registry.external_labels`: Labels added to all generated metrics
- `storage.path`: Write-ahead log for metrics before remote write
- `remote_write.url`: Prometheus-compatible endpoint (Mimir)
- `remote_write.send_exemplars: true`: **Critical** - enables exemplar transmission

**Note**: The `processors` configuration is commented out in the current setup. To enable metrics generation, uncomment and configure:

```yaml
metrics_generator:
  # ... existing config ...
  processor:
    service_graphs:
      dimensions: ['service.name', 'service.namespace']
      histogram_buckets: [0.1, 0.25, 0.5, 1, 2.5, 5, 10]
    span_metrics:
      dimensions:
        - name: http.method
        - name: http.status_code
        - name: service.name
      histogram_buckets: [0.002, 0.004, 0.008, 0.016, 0.032, 0.064, 0.128, 0.256, 0.512, 1.024, 2.048, 4.096, 8.192, 16.384]
      enable_target_info: true
```

### Mimir Configuration

Located in: `config/mimir-config.yaml`

```yaml
# Current configuration is basic - exemplar support is enabled by default
server:
  http_listen_port: 9009
  grpc_listen_port: 9095

# Exemplars are stored alongside metrics in blocks
blocks_storage:
  backend: filesystem
  filesystem:
    dir: /data/mimir-blocks
```

**Mimir Exemplar Support:**
- Exemplars are automatically stored when received via remote write
- No explicit configuration needed to enable exemplar storage
- Exemplars are kept with their associated metric samples

### Grafana Datasource Configuration

Located in: `config/grafana/provisioning/datasources/datasources.yaml`

```yaml
- name: Mimir-Prometheus
  type: prometheus
  uid: Mimir-Prometheus
  access: proxy
  url: http://mimir:9009
  jsonData:
    httpMethod: POST
    exemplarTraceIdDestinations:
      - name: trace_id
        datasourceUid: tempo
  isDefault: true
```

**Key Configuration:**

- `exemplarTraceIdDestinations`: Maps exemplar labels to trace datasources
  - `name: trace_id`: Label name containing the trace ID in exemplar data
  - `datasourceUid: tempo`: Target datasource for opening traces

## Metrics Generated with Exemplars

Tempo's metrics generator produces these metrics with exemplar support:

### Span Metrics

| Metric | Type | Description | Exemplar Attached |
|--------|------|-------------|-------------------|
| `traces_spanmetrics_calls_total` | Counter | Total count of spans by dimensions | Yes |
| `traces_spanmetrics_latency` | Histogram | Duration distribution of spans | Yes (on buckets) |
| `traces_spanmetrics_size_total` | Counter | Total size of spans ingested | Yes |

### Service Graph Metrics

| Metric | Type | Description | Exemplar Attached |
|--------|------|-------------|-------------------|
| `traces_service_graph_request_total` | Counter | Requests between services | Yes |
| `traces_service_graph_request_failed_total` | Counter | Failed requests between services | Yes |
| `traces_service_graph_request_server_seconds` | Histogram | Server-side request duration | Yes (on buckets) |
| `traces_service_graph_request_client_seconds` | Histogram | Client-side request duration | Yes (on buckets) |

**Exemplar Labels:**

Each exemplar includes:
- `trace_id`: The trace ID for correlation
- Potentially other custom labels from span attributes

## How to Enable Metrics Generation

The current Tempo configuration has metrics generation partially configured. To fully enable:

### 1. Uncomment and Configure Processors

Edit `config/tempo-config.yaml`:

```yaml
metrics_generator:
  registry:
    external_labels:
      source: tempo
      cluster: local-dev  # Optional: add environment identifier
  storage:
    path: /tmp/tempo/generator/wal
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true
        # Optional: authentication headers
        # headers:
        #   X-Scope-OrgID: tenant-1

  # Enable processors
  processor:
    # Service graph processor
    service_graphs:
      dimensions:
        - service.name
        - service.namespace
        - deployment.environment
      histogram_buckets: [0.1, 0.25, 0.5, 1, 2.5, 5, 10]

    # Span metrics processor
    span_metrics:
      dimensions:
        - name: http.method
        - name: http.status_code
        - name: http.route
        - name: service.name
        - name: service.namespace
        - name: deployment.environment
      # Customize buckets based on your latency requirements
      histogram_buckets: [0.002, 0.004, 0.008, 0.016, 0.032, 0.064, 0.128, 0.256, 0.512, 1.024, 2.048, 4.096, 8.192, 16.384]
      enable_target_info: true
```

### 2. Restart Tempo

```bash
docker compose restart tempo
```

### 3. Verify Metrics in Mimir

Query Mimir to check metrics are being written:

```bash
# Check for span metrics
curl -s 'http://localhost:9009/api/v1/query?query=traces_spanmetrics_calls_total' | jq

# Check for service graph metrics
curl -s 'http://localhost:9009/api/v1/query?query=traces_service_graph_request_total' | jq
```

### 4. Verify Exemplars

Query with exemplars enabled:

```bash
# Check histogram buckets for exemplars
curl -s 'http://localhost:9009/api/v1/query?query=traces_spanmetrics_latency_bucket' | jq '.data.result[0].exemplar'
```

## Using Exemplars in Grafana

### In Dashboards

1. **Create a panel** with a histogram metric (e.g., `traces_spanmetrics_latency`)
2. **Exemplars appear automatically** as highlighted dots on the graph
3. **Hover over exemplar** to see trace ID and labels
4. **Click exemplar** to open trace in Tempo

### In Explore

1. Navigate to **Explore** → Select **Mimir-Prometheus**
2. Query a histogram metric:
   ```promql
   rate(traces_spanmetrics_latency_bucket[5m])
   ```
3. Exemplars appear as blue diamonds on the visualization
4. Click any exemplar to view the corresponding trace

### Example Dashboard Query

```promql
# 99th percentile latency with exemplars
histogram_quantile(0.99,
  sum by (le, service_name) (
    rate(traces_spanmetrics_latency_bucket{service_name="my-service"}[5m])
  )
)
```

When this query is visualized, exemplars from high-latency traces will appear on the graph, allowing you to click through to investigate specific slow requests.

## Best Practices

### 1. Configure Appropriate Histogram Buckets

Choose buckets that align with your latency SLOs:

```yaml
# For sub-second API latencies
histogram_buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

# For longer-running operations (seconds to minutes)
histogram_buckets: [0.1, 0.5, 1, 5, 10, 30, 60, 120, 300]
```

### 2. Limit Dimension Cardinality

Be selective with dimensions to avoid metric explosion:

**Good dimensions** (low cardinality):
- `service.name` (tens of services)
- `http.method` (GET, POST, PUT, DELETE, etc.)
- `http.status_code` (200, 404, 500, etc.)
- `deployment.environment` (dev, staging, prod)

**Avoid** (high cardinality):
- `http.url` (unique per endpoint)
- `user.id` (unique per user)
- `trace.id` (unique per trace)
- `http.target` (may include query parameters)

### 3. Sampling Strategy

For high-throughput systems, exemplar sampling is critical:

```yaml
metrics_generator:
  processor:
    span_metrics:
      # Maximum exemplars to store per metric series
      max_exemplars: 100

      # Time window for exemplar collection
      exemplar_cache_size: 500
```

**Note**: Current Tempo config doesn't expose these settings - they use defaults. Consider the cardinality of your metrics when enabling.

### 4. Monitor Metrics Generator Resource Usage

Metrics generation adds overhead:

```bash
# Check Tempo container stats
docker stats tempo

# Check metrics generator WAL size
docker exec tempo du -sh /tmp/tempo/generator/wal
```

## Troubleshooting

### Exemplars Not Appearing in Grafana

**Possible causes:**

1. **Exemplars not sent from Tempo**
   - Verify `send_exemplars: true` in Tempo config
   - Check Tempo logs for remote write errors
   - Confirm processors are enabled

2. **Mimir not storing exemplars**
   - Check Mimir ingestion metrics
   - Verify Mimir has sufficient storage
   - Look for errors in Mimir logs

3. **Grafana datasource misconfigured**
   - Verify `exemplarTraceIdDestinations` is set
   - Check `datasourceUid` matches Tempo UID
   - Ensure exemplar label name matches (default: `trace_id`)

4. **No exemplars in time range**
   - Exemplars are sampled - may not exist for every data point
   - Try a longer time range or higher traffic periods
   - Check exemplar sampling configuration

### Exemplar Label Name Mismatch

If exemplars exist but don't link properly:

**Check exemplar labels in Mimir:**

```bash
curl -s 'http://localhost:9009/api/v1/query?query=traces_spanmetrics_latency_bucket' | \
  jq '.data.result[0].exemplar.labels'
```

**Expected output:**
```json
{
  "trace_id": "abc123def456",
  "span_id": "789xyz"
}
```

**If label is different**, update Grafana datasource:

```yaml
exemplarTraceIdDestinations:
  - name: traceID  # Match actual label name
    datasourceUid: tempo
```

### High Cardinality Issues

If metrics generation causes performance problems:

1. **Reduce dimensions**:
   ```yaml
   dimensions:
     - name: service.name
     - name: http.method
     # Remove high-cardinality dimensions like http.target
   ```

2. **Filter spans before metrics generation**:
   ```yaml
   span_metrics:
     filter_policies:
       - include:
           match_type: strict
           attributes:
             - key: span.kind
               value: SPAN_KIND_SERVER  # Only server spans
   ```

3. **Increase aggregation interval**:
   ```yaml
   registry:
     collection_interval: 30s  # Default: 15s
   ```

## Advanced Configuration

### Custom Exemplar Labels

Include additional context in exemplars:

```yaml
metrics_generator:
  processor:
    span_metrics:
      dimensions:
        - name: service.name
        - name: http.status_code
      # These will appear as exemplar labels
      exemplar_labels:
        - trace_id
        - span_id
        - deployment.environment
```

### Exemplar Filtering

Control which spans become exemplars:

```yaml
span_metrics:
  # Only create exemplars for errors or slow requests
  filter_policies:
    - include:
        match_type: regexp
        attributes:
          - key: http.status_code
            value: "5.*"  # 5xx errors
    - include:
        match_type: strict
        attributes:
          - key: span.duration_ms
            value: ">1000"  # Spans over 1 second
```

### Multi-Tenant Configuration

For multi-tenant setups:

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true
        headers:
          X-Scope-OrgID: ${TENANT_ID}
```

And set `remote_write_add_org_id_header: true` in Tempo config.

## Integration with @your-org/instrumentation

When using the org instrumentation library, exemplars work automatically:

```javascript
import {initOtelInstrumentation} from '@your-org/instrumentation';

// This sets up proper trace context propagation
initOtelInstrumentation({
    componentName: 'my-service'
});

// All traces will automatically include trace_id
// which becomes available as exemplar labels
```

The instrumentation ensures:
- Trace IDs are properly formatted
- Span context is propagated through services
- Attributes match metrics generator expectations

## Reference Links

- **Grafana Exemplars**: https://grafana.com/docs/grafana/latest/fundamentals/exemplars/
- **Tempo Metrics Generator**: https://grafana.com/docs/tempo/latest/metrics-generator/
- **Prometheus Exemplars**: https://prometheus.io/docs/prometheus/latest/feature_flags/#exemplars-storage
- **OpenTelemetry Metrics**: https://opentelemetry.io/docs/specs/otel/metrics/
