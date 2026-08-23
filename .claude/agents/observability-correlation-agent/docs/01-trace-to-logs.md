# Trace-to-Logs Correlation

## Overview

Trace-to-logs correlation enables seamless navigation from distributed traces in Tempo to corresponding log entries in Loki. This capability is essential for debugging and root cause analysis, allowing engineers to move from high-level trace spans to detailed log messages that provide context about what happened during specific operations.

## How It Works

The correlation mechanism works in both directions:

1. **Loki → Tempo (Derived Fields)**: Extract trace IDs from log messages and create clickable links to traces
2. **Tempo → Loki (tracesToLogs)**: From a trace span, automatically query Loki for related logs using span attributes and time ranges

## Current Configuration

### Loki Datasource Configuration

Located in: `config/grafana/provisioning/datasources/datasources.yaml`

```yaml
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

**Key Configuration Elements:**

- `derivedFields`: Extracts trace IDs from log messages
  - `datasourceUid: tempo`: Links to the Tempo datasource
  - `matcherRegex: traceID=(\w+)`: Regular expression to extract trace ID (expects format like `traceID=abc123def456`)
  - `name: TraceID`: Display label for the derived field
  - `url: $${__value.raw}`: Uses the captured trace ID value as the link target

### Tempo Datasource Configuration

```yaml
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

**Key Configuration Elements:**

- `tracesToLogs.datasourceUid`: Links to Loki datasource
- `tags`: Span attributes to use as Loki query labels
- `mappedTags`: Maps OpenTelemetry semantic conventions to Loki labels
  - `service.name` → `job`: Critical for matching traces to logs
- `spanStartTimeShift`/`spanEndTimeShift`: Time buffer around span (1 hour before/after)
- `filterByTraceID`: Includes trace ID in Loki query
- `filterBySpanID`: Whether to filter by specific span ID (disabled here)

## OpenTelemetry Semantic Conventions Integration

### Required Resource Attributes

For proper trace-to-logs correlation, your instrumented applications must emit these attributes:

```javascript
// Example with @your-org/instrumentation
import {initOtelInstrumentation} from '@your-org/instrumentation';

initOtelInstrumentation({
    componentName: 'your-service-name'  // Sets service.name
});
```

**Key Attributes:**
- `service.name` (required): Identifies the service generating telemetry
- `service.namespace` (recommended): Groups related services
- `service.instance.id` (recommended): Unique instance identifier
- `deployment.environment` (recommended): Environment name (dev, staging, prod)

### Attribute Mapping Strategy

The mapping configuration translates OTel attributes to Loki labels:

| OpenTelemetry Attribute | Loki Label | Purpose |
|-------------------------|------------|---------|
| `service.name` | `job` | Primary service identifier |
| `service.instance.id` | `instance` | Specific instance of service |
| `k8s.pod.name` | `pod` | Kubernetes pod name |
| `k8s.namespace.name` | `namespace` | Kubernetes namespace |

## Time Shift Configuration

The time shift parameters handle clock skew and ensure logs are captured:

```yaml
spanStartTimeShift: '1h'
spanEndTimeShift: '1h'
```

**Why This Matters:**
- Logs may not have exact timestamps matching span boundaries
- Application logging might occur slightly before/after span timing
- Buffering and asynchronous logging can introduce delays
- Clock drift between services can cause misalignment

**Configuration Values:**
- Format: Duration string (e.g., `30s`, `5m`, `1h`)
- Default: `0` (no shift)
- Current setting: `1h` before and after span
- **Production recommendation**: Start with `1m` and adjust based on observation

## Query Construction

When clicking a span in Tempo, Grafana constructs a Loki query like:

```logql
{job="your-service-name", instance="instance-id", pod="pod-name", namespace="default"}
  |= "traceID=abc123def456"
```

**Query Components:**
1. **Label selectors**: `{job="...", instance="...", ...}` - Filters logs by service/instance
2. **Trace ID filter**: `|= "traceID=abc123def456"` - Only logs mentioning the trace ID
3. **Time range**: Span start time - 1h to span end time + 1h

## Best Practices

### 1. Structured Logging with Trace Context

Ensure your application logs include trace ID:

```javascript
// Example with @your-org/instrumentation (automatically includes trace context)
import {initOtelInstrumentation} from '@your-org/instrumentation';
import {trace} from '@opentelemetry/api';

// Instrumentation automatically propagates trace context to logs
initOtelInstrumentation({
    componentName: 'my-service'
});

// In your logging, trace ID is automatically available
console.log('Processing request', {
    // OTel instrumentation adds these automatically:
    // traceID: '<current-trace-id>',
    // spanID: '<current-span-id>'
});
```

### 2. Consistent Label Names

Ensure Loki labels match the `tags` configured in Tempo:

```yaml
# Tempo expects these labels to exist in Loki
tags: ['job', 'instance', 'pod', 'namespace']

# Loki configuration must have these as labels (not indexed fields)
```

### 3. Label Cardinality Management

Be cautious with which span attributes you add to `tags`:

**Good tags** (low cardinality):
- `service.name` → `job`
- `deployment.environment` → `environment`
- `k8s.namespace.name` → `namespace`

**Avoid** (high cardinality):
- `http.url` (unique per request)
- `user.id` (unique per user)
- `trace.id` (unique per trace)

### 4. Regex Pattern for Derived Fields

The `matcherRegex` must match your logging format:

**Common patterns:**

```yaml
# Format: traceID=abc123
matcherRegex: "traceID=(\\w+)"

# Format: trace_id:abc123
matcherRegex: "trace_id:(\\w+)"

# Format: "traceId":"abc123"
matcherRegex: '"traceId":"(\\w+)"'

# Format: traceparent=00-abc123-def456-01 (W3C Trace Context)
matcherRegex: 'traceparent=00-([a-f0-9]{32})-'
```

### 5. Testing the Configuration

Verify trace-to-logs correlation:

1. **Generate test traces**: Send requests to your instrumented application
2. **View in Tempo**: Open Grafana → Explore → Select Tempo → Search for traces
3. **Click span**: Select a span and look for "Logs for this span" button
4. **Verify Loki query**: Check that logs appear with correct filters
5. **Click trace ID in logs**: Verify derived field links back to Tempo

## Troubleshooting

### No Logs Found When Clicking Span

**Possible causes:**

1. **Label mismatch**: Span attributes don't match Loki labels
   - Check `service.name` in spans matches `job` in Loki
   - Verify all tags exist as labels in Loki

2. **Time range too narrow**: Logs fall outside time shift window
   - Increase `spanStartTimeShift` and `spanEndTimeShift`
   - Check for significant clock drift

3. **Trace ID not in logs**: Application not logging trace context
   - Verify instrumentation is properly configured
   - Check log format includes `traceID=<value>`

4. **Loki query syntax issues**: Query construction failed
   - Check Grafana logs for errors
   - Verify datasource UIDs match configuration

### Derived Fields Not Appearing

**Possible causes:**

1. **Regex doesn't match**: Log format differs from pattern
   - Test regex against actual log messages
   - Update `matcherRegex` to match your format

2. **Datasource UID incorrect**: Tempo datasource not found
   - Verify `datasourceUid: tempo` matches Tempo datasource UID
   - Check datasource configurations are loaded

3. **Field hidden in UI**: Derived fields section collapsed
   - Expand "Fields" section in log details
   - Look for "TraceID" field with link icon

## Advanced Configuration

### Custom Query with Variables

For more control, use a custom query instead of automatic construction:

```yaml
tracesToLogs:
  datasourceUid: Loki
  customQuery: true
  query: '{job="${__span.tags["service.name"]}", namespace="${__span.tags["k8s.namespace.name"]}"} |= "traceID=${__trace.traceId}"'
```

**Available variables:**
- `${__trace.traceId}`: Full trace ID
- `${__span.spanId}`: Span ID
- `${__span.tags["attribute"]}`: Any span attribute
- `${__span.startTime}`: Span start timestamp
- `${__span.endTime}`: Span end timestamp

### Multiple Derived Fields

Extract multiple correlation points from logs:

```yaml
derivedFields:
  - datasourceUid: tempo
    matcherRegex: 'traceID=(\w+)'
    name: TraceID
    url: '$${__value.raw}'

  - datasourceUid: tempo
    matcherRegex: 'parentSpanID=(\w+)'
    name: ParentSpan
    url: '$${__value.raw}'

  - datasourceUid: Mimir-Prometheus
    matcherRegex: 'requestID=(\w+)'
    name: RequestMetrics
    url: '/explore?left={"datasource":"Mimir-Prometheus","queries":[{"expr":"http_requests_total{request_id=\"$${__value.raw}\"}"}]}'
```

## Reference Links

- **Grafana Tempo Configuration**: https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/
- **Loki Derived Fields**: https://grafana.com/docs/grafana/latest/datasources/loki/configure-loki-data-source/
- **OpenTelemetry Trace Context**: https://www.w3.org/TR/trace-context/
- **W3C Trace Context Propagation**: https://opentelemetry.io/docs/specs/otel/context/api-propagators/
