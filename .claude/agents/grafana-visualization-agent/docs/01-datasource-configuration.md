# Grafana Datasource Configuration

**Purpose**: Comprehensive guide for configuring Loki, Tempo, and Mimir/Prometheus datasources with cross-datasource linking.

**Last Updated**: 2025-11-28

---

## Overview

Grafana datasources can be configured via:
1. **UI** - Grafana Settings > Data Sources (manual configuration)
2. **YAML Provisioning** - File-based configuration (recommended for GitOps)

This guide focuses on YAML provisioning patterns for the LGTM stack.

---

## Datasource Provisioning Basics

### Configuration Location

```
config/grafana/provisioning/datasources/datasources.yaml
```

### Basic Structure

```yaml
apiVersion: 1

datasources:
  - name: DatasourceName
    type: datasource_type
    uid: unique_identifier
    access: proxy
    url: http://backend:port
    jsonData:
      # Type-specific configuration
    isDefault: false
```

### Key Fields

- **name** - Display name in Grafana UI
- **type** - Datasource type (`loki`, `tempo`, `prometheus`)
- **uid** - Unique identifier for cross-datasource linking
- **access** - Always `proxy` for server-side requests
- **url** - Backend service endpoint
- **jsonData** - Type-specific configuration object
- **isDefault** - Set one datasource as default

### Environment Variables

Use environment variables for dynamic configuration:

```yaml
datasources:
  - name: Loki
    url: http://${LOKI_HOST}:${LOKI_PORT}
    basicAuth: true
    basicAuthUser: ${LOKI_USER}
    secureJsonData:
      basicAuthPassword: ${LOKI_PASSWORD}
```

**Important**: Escape `$` in values using `$$` (e.g., `Pa$$sw0rd`)

---

## Loki Datasource Configuration

### Basic Loki Configuration

```yaml
datasources:
  - name: Loki
    type: loki
    uid: Loki
    access: proxy
    url: http://loki:3100
    jsonData:
      timeout: 60
      maxLines: 1000
    isDefault: false
```

### Configuration Options

**timeout** - Query timeout in seconds (default: 60)
**maxLines** - Maximum lines returned per query (default: 1000)

### Derived Fields - Linking Logs to Traces

Derived fields extract values from log lines and create links to other datasources (typically traces).

**Configuration Pattern**:

```yaml
datasources:
  - name: Loki
    type: loki
    uid: Loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        # Internal link to Tempo datasource
        - datasourceUid: tempo
          matcherRegex: traceID=(\w+)
          name: TraceID
          url: $${__value.raw}
          urlDisplayLabel: 'View Trace'

        # External link to Jaeger UI
        - matcherRegex: "traceID=(\\w+)"
          name: TraceID
          url: 'http://jaeger-ui:16686/trace/$${__value.raw}'
          urlDisplayLabel: 'Open in Jaeger'
```

**Key Fields**:

- **datasourceUid** - UID of target datasource (for internal links)
- **matcherRegex** - Regex to extract value from log line (use capturing group)
- **name** - Label shown in Grafana UI
- **url** - Link URL template using `$${__value.raw}` for captured value
- **urlDisplayLabel** - Custom link text (optional)

**Regex Patterns**:

```yaml
# Extract from: traceID=abc123
matcherRegex: traceID=(\w+)

# Extract from: trace_id="abc123"
matcherRegex: 'trace_id="([^"]+)"'

# Extract from: [TraceID: abc123]
matcherRegex: '\[TraceID:\s+(\w+)\]'

# Extract from JSON: {"traceId":"abc123"}
matcherRegex: '"traceId"\s*:\s*"([^"]+)"'
```

**Important**: Escape special regex characters in YAML using double backslashes:
- `\w` becomes `\\w`
- `\s` becomes `\\s`
- `\"` becomes `\\"`

### Current Project Configuration

From `config/grafana/provisioning/datasources/datasources.yaml`:

```yaml
datasources:
  - name: Loki
    type: loki
    uid: Loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: traceID=(\w+)
          name: TraceID
          url: $${__value.raw}
    isDefault: false
```

**Log Format Expected**: Logs should contain `traceID=<hex_string>` for automatic linking.

---

## Tempo Datasource Configuration

### Basic Tempo Configuration

```yaml
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      httpMethod: GET
    isDefault: false
```

**Important**: Use `httpMethod: GET` to prevent gRPC auto-detection issues.

### tracesToLogs - Linking Traces to Logs

Configure automatic linking from traces to related logs:

```yaml
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      httpMethod: GET
      tracesToLogs:
        datasourceUid: Loki
        tags: ['job', 'instance', 'pod', 'namespace']
        mappedTags:
          - key: 'service.name'
            value: 'job'
        mapTagNamesEnabled: false
        spanStartTimeShift: '1h'
        spanEndTimeShift: '1h'
        filterByTraceID: true
        filterBySpanID: false
        customQuery: false
```

**Configuration Fields**:

- **datasourceUid** - UID of Loki datasource
- **tags** - Span tags to use in log query (label matching)
- **mappedTags** - Map span tag names to log label names
  - `key`: Span tag name (e.g., `service.name`)
  - `value`: Log label name (e.g., `job`)
- **mapTagNamesEnabled** - Auto-map all matching tags
- **spanStartTimeShift** - Extend time range before span start
- **spanEndTimeShift** - Extend time range after span end
- **filterByTraceID** - Include `traceID=<id>` in log query
- **filterBySpanID** - Include `spanID=<id>` in log query
- **customQuery** - Use custom LogQL query (advanced)

**Generated LogQL Example**:

With `filterByTraceID: true` and tags `['job', 'instance']`:

```logql
{job="my-service", instance="pod-123"} |= "traceID=abc123def456"
```

### tracesToMetrics - Linking Traces to Metrics

Link traces to related Prometheus/Mimir metrics:

```yaml
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      tracesToMetrics:
        datasourceUid: Mimir-Prometheus
        spanStartTimeShift: '-1h'
        spanEndTimeShift: '1h'
        tags:
          - key: 'service.name'
            value: 'service'
          - key: 'job'
        queries:
          - name: 'Request Rate'
            query: 'sum(rate(http_requests_total{$__tags}[5m]))'
          - name: 'Error Rate'
            query: 'sum(rate(http_requests_total{$__tags, status=~"5.."}[5m]))'
```

**Configuration Fields**:

- **datasourceUid** - UID of Prometheus/Mimir datasource
- **spanStartTimeShift** - Extend time range before span
- **spanEndTimeShift** - Extend time range after span
- **tags** - Span tags to interpolate into metrics queries
- **queries** - List of PromQL queries to display
  - `name`: Query display name
  - `query`: PromQL with `$__tags` variable

**$__tags Variable**: Interpolates mapped tags as label matchers:

```promql
# Input: $__tags with service="my-app", job="api"
# Output: service="my-app", job="api"
sum(rate(http_requests_total{$__tags}[5m]))
# Becomes: sum(rate(http_requests_total{service="my-app", job="api"}[5m]))
```

### Service Graph and Search

```yaml
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      serviceMap:
        datasourceUid: Mimir-Prometheus
      search:
        hide: false
```

**serviceMap** - Enable service graph visualization using metrics from Prometheus/Mimir
**search.hide** - Show/hide search tab in Explore

**Note**: Service graph requires Tempo's metrics-generator to be enabled.

### Current Project Configuration

From `config/grafana/provisioning/datasources/datasources.yaml`:

```yaml
datasources:
  - name: Tempo
    type: tempo
    uid: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      httpMethod: GET
      tracesToLogs:
        datasourceUid: Loki
        tags: ['job', 'instance', 'pod', 'namespace']
        mappedTags:
          - key: 'service.name'
            value: 'job'
        mapTagNamesEnabled: false
        spanStartTimeShift: '1h'
        spanEndTimeShift: '1h'
        filterByTraceID: true
        filterBySpanID: false
      serviceMap:
        datasourceUid: Mimir-Prometheus
      search:
        hide: false
    isDefault: false
```

---

## Prometheus/Mimir Datasource Configuration

### Basic Mimir Configuration

Mimir is configured as a Prometheus datasource:

```yaml
datasources:
  - name: Mimir-Prometheus
    type: prometheus
    uid: Mimir-Prometheus
    access: proxy
    url: http://mimir:9009
    jsonData:
      httpMethod: POST
    isDefault: true
```

**httpMethod** - Use `POST` for large queries (recommended)

### Exemplars - Linking Metrics to Traces

Exemplars are specific trace samples attached to metric data points:

```yaml
datasources:
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
        - name: traceID
          datasourceUid: tempo
```

**Configuration**:

- **name** - Label name in exemplar data (e.g., `trace_id`, `traceID`)
- **datasourceUid** - UID of Tempo datasource

**How Exemplars Work**:

1. Instrumentation records metrics with exemplar trace IDs
2. Prometheus/Mimir stores exemplars alongside metric samples
3. Grafana displays exemplars as dots on time series graphs
4. Clicking an exemplar jumps to the trace in Tempo

**OpenTelemetry Example**:

```python
# Metrics with exemplars are automatically created by OTel SDKs
# when tracing and metrics are both enabled
from opentelemetry import trace, metrics

tracer = trace.get_tracer(__name__)
meter = metrics.get_meter(__name__)

counter = meter.create_counter("http_requests_total")

with tracer.start_as_current_span("handle_request") as span:
    counter.add(1)  # Exemplar automatically includes trace_id
```

### Query Editor Settings

```yaml
datasources:
  - name: Mimir-Prometheus
    type: prometheus
    uid: Mimir-Prometheus
    access: proxy
    url: http://mimir:9009
    jsonData:
      httpMethod: POST
      timeInterval: "15s"
      queryTimeout: "60s"
      cacheLevel: 'Low'
      disableMetricsLookup: false
```

**timeInterval** - Default scrape interval for rate calculations
**queryTimeout** - Query timeout in seconds
**cacheLevel** - Query cache behavior (`Low`, `Medium`, `High`, `None`)
**disableMetricsLookup** - Disable metric name auto-completion

### Current Project Configuration

From `config/grafana/provisioning/datasources/datasources.yaml`:

```yaml
datasources:
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

---

## Cross-Datasource Linking Summary

### Complete LGTM Stack Integration

```
┌──────────────────────────────────────────────┐
│          Grafana Datasources                 │
├──────────────────────────────────────────────┤
│                                              │
│  ┌──────────┐   derivedFields   ┌─────────┐ │
│  │   Loki   │ ─────────────────> │  Tempo  │ │
│  │ (Logs)   │                    │(Traces) │ │
│  └──────────┘                    └─────────┘ │
│       ▲                               │      │
│       │                               │      │
│       │  tracesToLogs                 │      │
│       └───────────────────────────────┘      │
│                                              │
│  ┌─────────────┐  exemplars  ┌─────────┐   │
│  │   Mimir     │ ───────────> │  Tempo  │   │
│  │ (Metrics)   │              │(Traces) │   │
│  └─────────────┘              └─────────┘   │
│       ▲                            │         │
│       │     tracesToMetrics        │         │
│       └────────────────────────────┘         │
│                                              │
└──────────────────────────────────────────────┘
```

### UID Consistency

**Critical**: Datasource UIDs must match across configurations:

```yaml
# Loki references Tempo by UID
- name: Loki
  uid: Loki
  jsonData:
    derivedFields:
      - datasourceUid: tempo  # Must match Tempo UID

# Tempo references Loki and Mimir by UID
- name: Tempo
  uid: tempo
  jsonData:
    tracesToLogs:
      datasourceUid: Loki  # Must match Loki UID
    serviceMap:
      datasourceUid: Mimir-Prometheus  # Must match Mimir UID

# Mimir references Tempo by UID
- name: Mimir-Prometheus
  uid: Mimir-Prometheus
  jsonData:
    exemplarTraceIdDestinations:
      - datasourceUid: tempo  # Must match Tempo UID
```

---

## Troubleshooting

### Derived Fields Not Appearing

**Symptom**: TraceID links not showing in log details

**Solutions**:
- Check regex pattern matches log format exactly
- Verify datasourceUid matches target datasource UID
- Ensure logs contain the expected pattern (e.g., `traceID=abc123`)
- Reload Grafana datasources

### Tempo gRPC Connection Errors

**Symptom**: `transport: Error while dialing dial tcp: connection refused`

**Solution**: Add `httpMethod: GET` to Tempo datasource configuration

```yaml
jsonData:
  httpMethod: GET  # Force HTTP, disable gRPC
```

### Exemplars Not Showing

**Symptoms**: No exemplar dots on time series graphs

**Solutions**:
- Verify instrumentation is recording exemplars
- Check `exemplarTraceIdDestinations` configuration
- Ensure Prometheus/Mimir has exemplars enabled
- Query must return histogram or counter with exemplars

### tracesToLogs Not Working

**Symptoms**: No "View Logs" button in trace view

**Solutions**:
- Verify Loki datasourceUid matches exactly
- Check tag mapping between spans and logs
- Ensure logs have matching labels (job, instance, etc.)
- Verify time range shifts are appropriate

---

## Best Practices

### 1. Use Unique, Descriptive UIDs

```yaml
# Good
uid: Loki
uid: tempo
uid: Mimir-Prometheus

# Avoid
uid: datasource1
uid: ds-12345
```

### 2. Always Configure Cross-Datasource Links

Enable full observability correlation:
- Logs → Traces (derived fields)
- Traces → Logs (tracesToLogs)
- Traces → Metrics (tracesToMetrics)
- Metrics → Traces (exemplars)

### 3. Use Provisioning for Production

**Avoid**: Manual UI configuration (lost on restart)
**Use**: YAML provisioning files (version controlled, reproducible)

### 4. Document Expected Log Formats

If using derived fields, document the log format pattern:

```yaml
# Expected log format: {"traceId":"abc123","message":"..."}
derivedFields:
  - matcherRegex: '"traceId"\s*:\s*"([^"]+)"'
    name: TraceID
```

### 5. Test Regex Patterns

Use regex testing tools before deployment:
- https://regex101.com/
- Test with actual log samples

### 6. Keep Time Shifts Reasonable

```yaml
# Good - 1 hour buffer
spanStartTimeShift: '1h'
spanEndTimeShift: '1h'

# Avoid - unnecessarily large
spanStartTimeShift: '24h'  # Too wide, slow queries
```

---

## Reference

**Official Documentation**:
- Loki datasource: https://grafana.com/docs/grafana/latest/datasources/loki/
- Tempo datasource: https://grafana.com/docs/grafana/latest/datasources/tempo/
- Prometheus datasource: https://grafana.com/docs/grafana/latest/datasources/prometheus/
- Provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/

**Current Project Files**:
- `config/grafana/provisioning/datasources/datasources.yaml`
