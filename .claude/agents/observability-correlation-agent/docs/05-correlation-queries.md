# Cross-Signal Correlation Queries

## Overview

This document provides practical examples of queries that correlate traces, logs, and metrics to solve real-world debugging scenarios. Cross-signal correlation is the key to efficient troubleshooting in distributed systems - starting with symptoms in metrics, drilling down to specific traces, and examining detailed logs.

## Investigation Workflows

### Workflow 1: Metrics → Traces → Logs

**Scenario**: High error rate observed in metrics dashboard

1. **Metrics**: Identify which service/endpoint has high errors
2. **Traces**: Find example traces with errors (via exemplars)
3. **Logs**: View detailed error messages and stack traces

### Workflow 2: Traces → Logs → Metrics

**Scenario**: Slow request reported by user

1. **Traces**: Search for trace by trace ID or user context
2. **Logs**: Find detailed logs for specific spans
3. **Metrics**: Check if pattern is systemic (affects all users)

### Workflow 3: Logs → Traces → Metrics

**Scenario**: Error message appears in logs

1. **Logs**: Find error message with trace ID
2. **Traces**: View full distributed trace context
3. **Metrics**: Determine frequency and impact

## Common Debugging Scenarios

### Scenario 1: Investigating High Latency

**Step 1: Identify slow services in metrics**

Query Mimir for P99 latency by service:

```promql
# P99 latency by service
histogram_quantile(0.99,
  sum by (le, service_name) (
    rate(traces_spanmetrics_latency_bucket{
      span_kind="SPAN_KIND_SERVER"
    }[5m])
  )
)
```

**Result**: `order-service` has P99 latency of 2.5 seconds

**Step 2: Click exemplar to view slow trace**

Click on an exemplar point in the P99 graph → Opens trace in Tempo

**Step 3: Identify slow span**

In trace view:
- Total trace time: 2.8 seconds
- `POST /orders` span: 2.6 seconds
- Child span `SELECT orders`: 2.5 seconds (bottleneck!)

**Step 4: View logs for slow database query**

Click "Logs for this span" button → Opens Loki with query:

```logql
{job="order-service", namespace="production"}
  |= "traceID=abc123def456"
  | json
  | line_format "{{.level}} {{.message}}"
```

**Result**: Logs show "Query timeout: SELECT * FROM orders WHERE user_id = 12345"

**Step 5: Check if pattern is systemic**

Return to metrics and query:

```promql
# Percentage of slow database queries
(
  sum(rate(traces_spanmetrics_calls_total{
    service_name="order-service",
    db_system="postgresql",
    http_status_code="500"
  }[5m]))
  /
  sum(rate(traces_spanmetrics_calls_total{
    service_name="order-service",
    db_system="postgresql"
  }[5m]))
) * 100
```

**Result**: 15% of database queries are timing out

### Scenario 2: Tracking Down Intermittent Errors

**Step 1: Find error pattern in logs**

Query Loki for errors:

```logql
{job="payment-service", namespace="production"}
  |= "ERROR"
  | json
  | level="error"
```

**Result**: Multiple "Connection refused" errors to external payment API

**Step 2: Extract trace IDs from error logs**

In Loki, look for derived field "TraceID" → Click to view trace

**Step 3: Analyze trace context**

Trace shows:
- `payment-service` calling `external-payment-api`
- Span status: `ERROR`
- Span attributes: `http.status_code=503`

**Step 4: Correlate with service graph metrics**

Query for error rate between services:

```promql
# Error rate from payment-service to external API
(
  rate(traces_service_graph_request_failed_total{
    client="payment-service",
    server="external-payment-api"
  }[5m])
  /
  rate(traces_service_graph_request_total{
    client="payment-service",
    server="external-payment-api"
  }[5m])
) * 100
```

**Result**: 8% error rate, started 30 minutes ago

**Step 5: Check external service latency**

```promql
# P99 latency to external API
histogram_quantile(0.99,
  sum by (le) (
    rate(traces_service_graph_request_client_seconds_bucket{
      client="payment-service",
      server="external-payment-api"
    }[5m])
  )
)
```

**Result**: P99 latency increased from 200ms to 5 seconds

**Conclusion**: External payment API is degraded (high latency + intermittent failures)

### Scenario 3: Debugging Missing Data

**Step 1: User reports missing order**

User provides: Order ID `12345`, submitted at `2024-11-28 14:30:00 UTC`

**Step 2: Search traces by attribute**

In Tempo Explore, use TraceQL:

```traceql
{
  resource.service.name="order-service" &&
  span.http.route="/api/orders" &&
  span.http.method="POST"
} |
duration > 0s &&
span.order_id="12345"
```

**Result**: No traces found

**Step 3: Check if traces are being dropped**

Query Mimir for trace ingestion metrics:

```promql
# Tempo ingestion rate
rate(tempo_distributor_spans_received_total[5m])

# Tempo drop rate
rate(tempo_discarded_spans_total[5m])
```

**Result**: No dropped spans, traces should exist

**Step 4: Widen search in logs**

Query Loki without trace ID:

```logql
{job="order-service", namespace="production"}
  |= "12345"
  | json
  | order_id="12345"
```

**Result**: Found log entry: "Order 12345 rejected: invalid payment method"

**Step 5: Check if span was created**

Look for any trace activity around timestamp:

```traceql
{
  resource.service.name="order-service" &&
  span.http.route="/api/orders"
}
```

With time range: `2024-11-28 14:29:00` to `2024-11-28 14:31:00`

**Result**: Found trace with `http.status_code=400`, span has `validation_error="invalid_payment_method"`

**Conclusion**: Order was rejected (400 status), not a data loss issue

### Scenario 4: Investigating Memory Leaks

**Step 1: Notice increasing memory usage in metrics**

```promql
# Container memory usage
container_memory_usage_bytes{
  pod=~"user-service-.*",
  namespace="production"
}
```

**Result**: Memory growing linearly, reaches limit and OOMKills

**Step 2: Correlate with request patterns**

```promql
# Request rate to user-service
rate(traces_spanmetrics_calls_total{
  service_name="user-service",
  span_kind="SPAN_KIND_SERVER"
}[5m])
```

**Result**: Request rate is stable, memory growth not correlated with traffic

**Step 3: Check for specific endpoints**

```promql
# Requests by HTTP route
sum by (http_route) (
  rate(traces_spanmetrics_calls_total{
    service_name="user-service"
  }[5m])
)
```

**Result**: `/api/users/export` endpoint called occasionally

**Step 4: Find traces for export endpoint**

```traceql
{
  resource.service.name="user-service" &&
  span.http.route="/api/users/export"
}
```

**Result**: Traces show very long duration (60+ seconds)

**Step 5: View logs for export operations**

Click span → "Logs for this span":

```logql
{job="user-service"}
  |= "traceID=<trace-id>"
  | json
  | line_format "{{.level}} {{.message}} {{.memory_used}}"
```

**Result**: Logs show memory allocation increasing during export, not released after

**Conclusion**: Memory leak in export endpoint, holds user data in memory

## Query Patterns

### Pattern 1: Find Traces with Errors

**TraceQL (in Tempo):**

```traceql
# All error traces
{ status = error }

# Errors in specific service
{
  resource.service.name="order-service" &&
  status = error
}

# HTTP 5xx errors
{
  span.http.response.status_code >= 500
}

# Errors with specific message
{
  status = error
} | span.status.message =~ ".*database timeout.*"
```

### Pattern 2: Find Slow Traces

**TraceQL:**

```traceql
# Traces over 5 seconds
{ duration > 5s }

# Slow database queries
{
  resource.service.name="order-service" &&
  span.db.system="postgresql" &&
  duration > 1s
}

# Slow external API calls
{
  span.kind = client &&
  span.http.target =~ ".*external-api.*" &&
  duration > 2s
}
```

### Pattern 3: Trace to Logs Correlation

**Loki query by trace ID:**

```logql
# Find logs for specific trace
{job="order-service"}
  |= "traceID=abc123def456"

# Parse JSON and filter
{job="order-service"}
  |= "traceID=abc123def456"
  | json
  | level=~"error|warn"

# Format output
{job="order-service"}
  |= "traceID=abc123def456"
  | json
  | line_format "{{.timestamp}} [{{.level}}] {{.message}}"
```

### Pattern 4: Logs to Trace Correlation

**Loki query with derived fields:**

```logql
# Find errors with trace IDs
{job="payment-service"}
  |= "ERROR"
  | json
  | level="error"
  | line_format "{{.message}} (trace: {{.traceID}})"

# Click derived field "TraceID" to open trace
```

### Pattern 5: Metrics to Traces via Exemplars

**PromQL with exemplars (in Grafana):**

```promql
# Request rate with exemplars
rate(traces_spanmetrics_calls_total{
  service_name="order-service"
}[5m])

# Error rate with exemplars showing failing traces
rate(traces_spanmetrics_calls_total{
  service_name="order-service",
  status_code=~"5.."
}[5m])

# Latency histogram with exemplars showing slow traces
histogram_quantile(0.99,
  sum by (le, service_name) (
    rate(traces_spanmetrics_latency_bucket[5m])
  )
)
```

Click blue diamond (exemplar) → Opens trace

### Pattern 6: Service-to-Service Error Analysis

**Service graph queries:**

```promql
# All failing edges
traces_service_graph_request_failed_total > 0

# Error rate by client-server pair
(
  rate(traces_service_graph_request_failed_total[5m])
  /
  rate(traces_service_graph_request_total[5m])
) * 100

# Most unreliable dependencies (top 10)
topk(10,
  rate(traces_service_graph_request_failed_total[5m])
)
```

### Pattern 7: Trace Sampling Analysis

**Check sampling rates:**

```promql
# Traces sampled vs total
(
  rate(tempo_ingester_traces_created_total[5m])
  /
  rate(tempo_distributor_spans_received_total[5m])
) * 100
```

**Find sampled vs non-sampled in logs:**

```logql
# All logs with trace context
{job="order-service"}
  | json
  | traceID != ""

# Count by sampled/not-sampled
sum by (sampled) (
  count_over_time(
    {job="order-service"}
      | json
      | traceID != ""
      [5m]
  )
)
```

## Advanced Correlation Techniques

### Technique 1: Multi-Service Transaction Tracing

Track request across multiple services using trace ID:

**Step 1: Start with root service trace**

```traceql
{
  resource.service.name="api-gateway" &&
  span.http.route="/api/checkout"
}
```

**Step 2: Get trace ID from result**, then query logs from all services:

```logql
{namespace="production"}
  |= "traceID=abc123def456"
  | json
  | line_format "{{.service_name}}: {{.message}}"
```

**Result**: See log messages from gateway → order-service → payment-service → inventory-service

### Technique 2: User Journey Reconstruction

Track all traces for a specific user:

**Step 1: Find user's traces**

```traceql
{
  span.user_id="user-67890"
}
```

**Step 2: For each trace, get logs**

```logql
{namespace="production"}
  |= "user-67890"
  | json
  | line_format "{{.timestamp}} {{.service_name}} {{.message}}"
```

**Step 3: Aggregate metrics for user's activity**

```promql
# User's request rate
sum(rate(traces_spanmetrics_calls_total{
  user_id="user-67890"
}[1h]))

# User's error rate
sum(rate(traces_spanmetrics_calls_total{
  user_id="user-67890",
  status_code=~"5.."
}[1h]))
```

### Technique 3: Anomaly Detection

Compare current behavior to baseline:

**Step 1: Current error rate**

```promql
# Current 5min error rate
rate(traces_spanmetrics_calls_total{
  service_name="order-service",
  status_code=~"5.."
}[5m])
```

**Step 2: Baseline error rate (same time yesterday)**

```promql
# Error rate 24 hours ago
rate(traces_spanmetrics_calls_total{
  service_name="order-service",
  status_code=~"5.."
}[5m] offset 24h)
```

**Step 3: Percentage increase**

```promql
# Error rate increase %
(
  rate(traces_spanmetrics_calls_total{
    service_name="order-service",
    status_code=~"5.."
  }[5m])
  /
  rate(traces_spanmetrics_calls_total{
    service_name="order-service",
    status_code=~"5.."
  }[5m] offset 24h)
  - 1
) * 100
```

**Step 4: If anomaly detected, find exemplar traces**

Click exemplar in current error rate graph → Investigate trace

### Technique 4: Dependency Analysis

Identify which downstream service is causing problems:

**Step 1: Get all downstream dependencies**

```promql
# All services called by order-service
sum by (server) (
  rate(traces_service_graph_request_total{
    client="order-service"
  }[5m])
)
```

**Step 2: Find slowest dependency**

```promql
# P99 latency by downstream service
histogram_quantile(0.99,
  sum by (le, server) (
    rate(traces_service_graph_request_client_seconds_bucket{
      client="order-service"
    }[5m])
  )
)
```

**Result**: `payment-service` has P99 of 3 seconds

**Step 3: Check payment-service internal performance**

```promql
# payment-service internal latency
histogram_quantile(0.99,
  sum by (le) (
    rate(traces_spanmetrics_latency_bucket{
      service_name="payment-service",
      span_kind="SPAN_KIND_SERVER"
    }[5m])
  )
)
```

**Result**: Payment-service itself is only 100ms

**Conclusion**: Network latency between order-service and payment-service (3s client - 0.1s server = 2.9s network)

### Technique 5: Error Correlation Across Signals

Find the relationship between different error types:

**Step 1: Metric - overall error rate**

```promql
sum(rate(traces_spanmetrics_calls_total{
  status_code=~"5.."
}[5m]))
```

**Step 2: Trace - break down by error type**

```traceql
{ status = error }
| groupby(span.status.message)
```

**Step 3: Logs - detailed error messages**

```logql
{namespace="production"}
  |= "ERROR"
  | json
  | level="error"
  | __error__=""
```

**Step 4: Correlate by timestamp**

Look for spike in all three signals at same time → Indicates systemic issue

## Grafana Dashboard Examples

### Dashboard 1: Golden Signals with Drill-Down

**Row 1: Request Rate**
```promql
sum by (service_name) (
  rate(traces_spanmetrics_calls_total{
    span_kind="SPAN_KIND_SERVER"
  }[5m])
)
```
Click service name → Filter entire dashboard

**Row 2: Error Rate**
```promql
sum by (service_name) (
  rate(traces_spanmetrics_calls_total{
    span_kind="SPAN_KIND_SERVER",
    status_code=~"5.."
  }[5m])
)
```
Click exemplar → Open trace

**Row 3: Latency**
```promql
histogram_quantile(0.99,
  sum by (le, service_name) (
    rate(traces_spanmetrics_latency_bucket{
      span_kind="SPAN_KIND_SERVER"
    }[5m])
  )
)
```
Click exemplar → Open slow trace

**Row 4: Saturation**
```promql
container_memory_usage_bytes{
  namespace="production"
}
```

### Dashboard 2: Service Dependency Map

**Panel 1: Service Graph**
- Datasource: Tempo
- Visualization: Service Graph
- Auto-generated from traces

**Panel 2: Top Errors by Edge**
```promql
topk(10,
  sum by (client, server) (
    rate(traces_service_graph_request_failed_total[5m])
  )
)
```

**Panel 3: Logs Panel**
- Datasource: Loki
- Variable: `$traceID` (set by clicking trace)
- Query:
```logql
{namespace="production"}
  |= "$traceID"
```

### Dashboard 3: User Experience Monitor

**Panel 1: Request Success Rate**
```promql
(
  sum(rate(traces_spanmetrics_calls_total{
    service_name="api-gateway",
    status_code=~"2.."
  }[5m]))
  /
  sum(rate(traces_spanmetrics_calls_total{
    service_name="api-gateway"
  }[5m]))
) * 100
```

**Panel 2: P95 Latency by Endpoint**
```promql
histogram_quantile(0.95,
  sum by (le, http_route) (
    rate(traces_spanmetrics_latency_bucket{
      service_name="api-gateway"
    }[5m])
  )
)
```

**Panel 3: Error Logs Table**
```logql
{job="api-gateway"}
  |= "ERROR"
  | json
  | level="error"
  | line_format "{{.timestamp}} {{.http_route}} {{.message}}"
```

## Best Practices

### 1. Start Wide, Then Narrow

Begin with high-level metrics, then drill down:
1. System-wide error rate
2. Service-specific error rate
3. Endpoint-specific errors
4. Individual failing traces
5. Detailed logs for root cause

### 2. Use Time Correlation

When investigating issues:
- Note the time range when problem started
- Use the same time range across all signals
- Look for correlated spikes/changes
- Check for recent deployments or config changes

### 3. Leverage Exemplars

Always visualize metrics with exemplars enabled:
- Provides direct path from aggregate to specific instance
- Shows real examples of slow/failing requests
- Reduces time to resolution

### 4. Create Runbooks with Query Templates

Document common scenarios with pre-built queries:
- "High latency investigation"
- "Error spike response"
- "Dependency failure drill-down"
- "User-reported issue triage"

### 5. Use Variables in Dashboards

Create flexible dashboards with variables:
- `$service`: Filter by service
- `$environment`: prod/staging/dev
- `$traceID`: Auto-populate from clicks
- `$timeRange`: Consistent time selection

## Reference Links

- **TraceQL Documentation**: https://grafana.com/docs/tempo/latest/traceql/
- **LogQL Documentation**: https://grafana.com/docs/loki/latest/logql/
- **PromQL Documentation**: https://prometheus.io/docs/prometheus/latest/querying/basics/
- **Grafana Explore**: https://grafana.com/docs/grafana/latest/explore/
- **Tempo Correlation Features**: https://grafana.com/docs/tempo/latest/operations/correlate-logs-and-traces/
