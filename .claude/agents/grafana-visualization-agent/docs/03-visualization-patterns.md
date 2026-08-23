# Grafana Visualization Patterns and Best Practices

**Purpose**: Comprehensive guide for panel types, observability dashboard design, and visualization best practices.

**Last Updated**: 2025-11-28

---

## Overview

Effective observability dashboards follow established methodologies:
- **RED Method** - For microservices (Rate, Errors, Duration)
- **USE Method** - For infrastructure (Utilization, Saturation, Errors)
- **Four Golden Signals** - RED + Saturation (Google SRE)

This guide covers panel types, layout patterns, and practical dashboard design.

---

## Panel Types for Observability

### Time Series (Primary Metric Visualization)

**Best For**: Metrics over time, trends, anomaly detection

```json
{
  "type": "timeseries",
  "title": "Request Rate",
  "targets": [
    {
      "expr": "sum(rate(http_requests_total[5m])) by (service)",
      "legendFormat": "{{service}}",
      "refId": "A"
    }
  ],
  "options": {
    "tooltip": {
      "mode": "multi",
      "sort": "desc"
    },
    "legend": {
      "displayMode": "table",
      "placement": "right",
      "showLegend": true,
      "calcs": ["mean", "lastNotNull", "max", "min"]
    }
  },
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "color": {
        "mode": "palette-classic"
      },
      "custom": {
        "lineWidth": 2,
        "fillOpacity": 10,
        "pointSize": 5,
        "lineInterpolation": "smooth",
        "spanNulls": true,
        "drawStyle": "line",
        "axisPlacement": "auto",
        "axisLabel": "",
        "scaleDistribution": {
          "type": "linear"
        }
      },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"value": null, "color": "green"},
          {"value": 80, "color": "yellow"},
          {"value": 100, "color": "red"}
        ]
      }
    }
  }
}
```

**Key Options**:

- **drawStyle**: `line`, `bars`, `points`
- **lineInterpolation**: `linear`, `smooth`, `stepBefore`, `stepAfter`
- **fillOpacity**: 0-100 (area under line)
- **lineWidth**: 1-10 (line thickness)
- **pointSize**: 1-20 (marker size)
- **spanNulls**: Connect across null values

**Legend Calculations**:
- `mean` - Average value
- `lastNotNull` - Current/latest value
- `max` - Maximum value
- `min` - Minimum value
- `total` - Sum of all values
- `first` - First value
- `count` - Number of values
- `range` - max - min

### Stat Panel (Single Value)

**Best For**: Current state, KPIs, thresholds

```json
{
  "type": "stat",
  "title": "Error Rate",
  "targets": [
    {
      "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m])) * 100",
      "refId": "A"
    }
  ],
  "options": {
    "graphMode": "area",
    "colorMode": "value",
    "orientation": "auto",
    "textMode": "value_and_name",
    "reduceOptions": {
      "values": false,
      "calcs": ["lastNotNull"]
    }
  },
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "decimals": 2,
      "color": {
        "mode": "thresholds"
      },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"value": null, "color": "green"},
          {"value": 1, "color": "yellow"},
          {"value": 5, "color": "red"}
        ]
      }
    }
  }
}
```

**Options**:

- **graphMode**: `none`, `area`, `line` (sparkline background)
- **colorMode**: `none`, `value`, `background` (where to apply threshold color)
- **textMode**: `auto`, `value`, `value_and_name`, `name`, `none`
- **orientation**: `auto`, `horizontal`, `vertical`

**Use Cases**:
- Error rates with thresholds
- Current request rate
- Active connections
- Resource utilization percentage

### Gauge Panel

**Best For**: Percentage metrics, capacity monitoring

```json
{
  "type": "gauge",
  "title": "CPU Usage",
  "targets": [
    {
      "expr": "avg(rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) * 100",
      "refId": "A"
    }
  ],
  "options": {
    "showThresholdLabels": true,
    "showThresholdMarkers": true
  },
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "min": 0,
      "max": 100,
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"value": null, "color": "green"},
          {"value": 70, "color": "yellow"},
          {"value": 85, "color": "red"}
        ]
      }
    }
  }
}
```

**Best For**: CPU, memory, disk usage (0-100%)

### Bar Gauge

**Best For**: Comparing multiple services/metrics

```json
{
  "type": "bargauge",
  "title": "Service Response Times",
  "targets": [
    {
      "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (service, le))",
      "legendFormat": "{{service}}",
      "refId": "A"
    }
  ],
  "options": {
    "orientation": "horizontal",
    "displayMode": "gradient",
    "showUnfilled": true
  },
  "fieldConfig": {
    "defaults": {
      "unit": "s",
      "min": 0,
      "max": 2,
      "thresholds": {
        "steps": [
          {"value": null, "color": "green"},
          {"value": 0.5, "color": "yellow"},
          {"value": 1, "color": "red"}
        ]
      }
    }
  }
}
```

**displayMode**: `basic`, `lcd`, `gradient`
**orientation**: `horizontal`, `vertical`

### Logs Panel

**Best For**: Log stream visualization, error investigation

```json
{
  "type": "logs",
  "title": "Application Logs",
  "targets": [
    {
      "datasource": {"type": "loki", "uid": "Loki"},
      "expr": "{job=\"$service\"} |= \"$search\" | json | level=~\"$level\"",
      "refId": "A"
    }
  ],
  "options": {
    "showTime": true,
    "showLabels": true,
    "showCommonLabels": false,
    "wrapLogMessage": false,
    "prettifyLogMessage": true,
    "enableLogDetails": true,
    "dedupStrategy": "none",
    "sortOrder": "Descending"
  }
}
```

**Options**:

- **showTime**: Display timestamp
- **showLabels**: Show log labels
- **showCommonLabels**: Show labels common to all logs
- **wrapLogMessage**: Wrap long lines
- **prettifyLogMessage**: Format JSON logs
- **enableLogDetails**: Click to expand log details
- **dedupStrategy**: `none`, `exact`, `numbers`, `signature`
- **sortOrder**: `Descending` (newest first), `Ascending`

**LogQL Patterns**:

```logql
# Filter by level
{job="api"} | json | level="error"

# Search with regex
{job="api"} |~ "(?i)exception|error"

# Parse and filter
{job="api"} | json | duration > 1s

# Line format
{job="api"} | json | line_format "{{.timestamp}} [{{.level}}] {{.message}}"
```

### Traces Panel

**Best For**: Distributed trace visualization

```json
{
  "type": "traces",
  "title": "Trace Timeline",
  "targets": [
    {
      "datasource": {"type": "tempo", "uid": "tempo"},
      "queryType": "traceql",
      "query": "{service.name=\"$service\" && duration > 1s}",
      "refId": "A"
    }
  ]
}
```

**TraceQL Patterns**:

```traceql
# By service name
{service.name="api-gateway"}

# By duration
{duration > 1s}

# By HTTP status
{http.status_code = 500}

# Combined filters
{service.name="api" && http.method="POST" && duration > 500ms}

# Span-level filtering
{service.name="api" && span.http.status_code >= 400}
```

**Integration**: Works seamlessly with derived fields from Loki logs.

### Node Graph (Service Map)

**Best For**: Service dependencies, traffic flow visualization

```json
{
  "type": "nodeGraph",
  "title": "Service Map",
  "targets": [
    {
      "datasource": {"type": "tempo", "uid": "tempo"},
      "queryType": "serviceMap",
      "refId": "A"
    }
  ],
  "options": {
    "nodes": {
      "mainStatUnit": "short",
      "secondaryStatUnit": "short",
      "arcs": [
        {
          "field": "success_rate",
          "color": "green"
        },
        {
          "field": "error_rate",
          "color": "red"
        }
      ]
    }
  }
}
```

**Requires**: Tempo service graph (metrics-generator enabled)

### Table Panel

**Best For**: Detailed data, comparisons, logs summary

```json
{
  "type": "table",
  "title": "Service Metrics Summary",
  "targets": [
    {
      "expr": "sum(rate(http_requests_total[5m])) by (service)",
      "format": "table",
      "instant": true,
      "refId": "A"
    }
  ],
  "options": {
    "showHeader": true,
    "sortBy": [
      {
        "displayName": "Value",
        "desc": true
      }
    ]
  },
  "fieldConfig": {
    "overrides": [
      {
        "matcher": {"id": "byName", "options": "Value"},
        "properties": [
          {
            "id": "custom.displayMode",
            "value": "color-background"
          },
          {
            "id": "unit",
            "value": "reqps"
          }
        ]
      }
    ]
  }
}
```

**Display Modes**:
- `auto` - Default text
- `color-text` - Apply threshold colors to text
- `color-background` - Colored cell background
- `gradient-gauge` - Horizontal gauge in cell
- `lcd-gauge` - LCD-style gauge

### Heatmap

**Best For**: Latency distribution, request patterns

```json
{
  "type": "heatmap",
  "title": "Request Latency Distribution",
  "targets": [
    {
      "expr": "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)",
      "format": "heatmap",
      "legendFormat": "{{le}}",
      "refId": "A"
    }
  ],
  "options": {
    "calculate": false,
    "calculation": {},
    "cellGap": 2,
    "cellRadius": 0,
    "color": {
      "exponent": 0.5,
      "fill": "dark-orange",
      "mode": "scheme",
      "scheme": "Spectral",
      "steps": 128
    },
    "exemplars": {
      "color": "rgba(255,0,255,0.7)"
    }
  }
}
```

**Use Cases**:
- p50, p95, p99 latency visualization over time
- Request duration patterns
- Resource usage distribution

---

## Observability Dashboard Patterns

### RED Method Dashboard

**Purpose**: Monitor microservice health (Rate, Errors, Duration)

**Layout Pattern**:

```
┌─────────────┬─────────────┬─────────────┐
│ Request Rate│ Error Rate  │ P95 Latency │  Stat panels (current state)
│   (Stat)    │   (Stat)    │   (Stat)    │
├─────────────┴─────────────┴─────────────┤
│ Request Rate Over Time (Time Series)    │  Request rate trend
│                                          │
├──────────────────────────────────────────┤
│ Error Rate Over Time (Time Series)      │  Error rate trend
│                                          │
├──────────────────────────────────────────┤
│ Latency Percentiles (Time Series)       │  P50, P95, P99
│                                          │
├──────────────────────────────────────────┤
│ Recent Errors (Logs)                     │  Error logs with trace links
│                                          │
└──────────────────────────────────────────┘
```

**Key Metrics**:

```promql
# Rate (requests per second)
sum(rate(http_requests_total{service="$service"}[5m]))

# Errors (error rate percentage)
sum(rate(http_requests_total{service="$service",status=~"5.."}[5m])) /
sum(rate(http_requests_total{service="$service"}[5m])) * 100

# Duration (P50, P95, P99)
histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{service="$service"}[5m])) by (le))
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service="$service"}[5m])) by (le))
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service="$service"}[5m])) by (le))
```

**Row-Based Organization**:

```json
{
  "panels": [
    {"type": "row", "title": "Request Metrics"},
    // Request rate panels
    {"type": "row", "title": "Error Tracking"},
    // Error rate panels and logs
    {"type": "row", "title": "Latency Analysis"},
    // Duration/latency panels
    {"type": "row", "title": "Distributed Traces"},
    // Traces and service graph
  ]
}
```

### USE Method Dashboard

**Purpose**: Monitor infrastructure resources (Utilization, Saturation, Errors)

**For**: Nodes, containers, network devices, storage

```
┌─────────────┬─────────────┬─────────────┐
│ CPU Usage   │ Memory Usage│ Disk Usage  │  Gauges (utilization)
│   (Gauge)   │   (Gauge)   │   (Gauge)   │
├─────────────┼─────────────┼─────────────┤
│ Load Avg    │ Mem Pressure│ I/O Wait    │  Stats (saturation)
│   (Stat)    │   (Stat)    │   (Stat)    │
├─────────────┴─────────────┴─────────────┤
│ CPU Utilization Over Time               │  Time series
│                                          │
├──────────────────────────────────────────┤
│ Memory Usage Over Time                  │  Time series
│                                          │
├──────────────────────────────────────────┤
│ System Errors (Logs)                    │  Error logs
│                                          │
└──────────────────────────────────────────┘
```

**Key Metrics**:

```promql
# Utilization (CPU)
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Utilization (Memory)
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Saturation (Load average)
node_load1 / count(node_cpu_seconds_total{mode="system"})

# Errors (Disk I/O errors)
rate(node_disk_io_errors_total[5m])
```

### Multi-Service Comparison

**Purpose**: Compare metrics across multiple services

**Layout Pattern**:

```
┌──────────────────────────────────────────┐
│ Services: [all] [api] [worker] [db]     │  Variable selection
├──────────────────────────────────────────┤
│ Request Rate by Service (Bar Gauge)     │  Horizontal comparison
│                                          │
├──────────────────────────────────────────┤
│ Request Rate Over Time (Time Series)    │  Multi-line graph
│  - api (blue), worker (green), db (red) │
│                                          │
├──────────────────────────────────────────┤
│ Service Summary (Table)                  │  Detailed comparison
│  Service | Rate | Errors | P95          │
│  api     | 500  | 0.5%   | 150ms        │
│  worker  | 200  | 0.1%   | 50ms         │
└──────────────────────────────────────────┘
```

**Key Query Pattern**:

```promql
# Group by service
sum(rate(http_requests_total[5m])) by (service)

# Filter by selected services
sum(rate(http_requests_total{service=~"$service"}[5m])) by (service)
```

### LGTM Stack Health Dashboard

**Purpose**: Monitor observability stack itself

```
┌─────────────┬─────────────┬─────────────┐
│ Loki        │ Tempo       │ Mimir       │  Component status
│ Ingestion   │ Traces/sec  │ Series Count│
├─────────────┴─────────────┴─────────────┤
│ Loki Ingestion Rate (Time Series)       │
│                                          │
├──────────────────────────────────────────┤
│ Tempo Ingestion Rate (Time Series)      │
│                                          │
├──────────────────────────────────────────┤
│ Mimir Active Series (Time Series)       │
│                                          │
├──────────────────────────────────────────┤
│ Component Logs (Logs)                   │  Stack component logs
│                                          │
└──────────────────────────────────────────┘
```

**Key Metrics**:

```promql
# Loki
sum(rate(loki_distributor_bytes_received_total[5m]))
sum(rate(loki_distributor_lines_received_total[5m]))

# Tempo
sum(rate(tempo_distributor_spans_received_total[5m]))
sum(rate(tempo_ingester_traces_created_total[5m]))

# Mimir
sum(cortex_ingester_memory_series)
sum(rate(cortex_distributor_received_samples_total[5m]))
```

---

## Color and Threshold Strategies

### Meaningful Color Usage

**Principle**: Blue = good, Red = bad (consistent convention)

**Good Example**:

```json
"thresholds": {
  "steps": [
    {"value": null, "color": "green"},   // 0-80: good
    {"value": 80, "color": "yellow"},    // 80-95: warning
    {"value": 95, "color": "red"}        // 95+: critical
  ]
}
```

**Bad Example**:

```json
// Inconsistent: Red at low values
"thresholds": {
  "steps": [
    {"value": null, "color": "red"},     // Confusing
    {"value": 50, "color": "green"}
  ]
}
```

### Threshold Patterns

**Error Rate** (0-100%):

```json
"thresholds": {
  "steps": [
    {"value": null, "color": "green"},
    {"value": 1, "color": "yellow"},
    {"value": 5, "color": "red"}
  ]
}
```

**Latency** (milliseconds):

```json
"thresholds": {
  "steps": [
    {"value": null, "color": "green"},
    {"value": 500, "color": "yellow"},
    {"value": 1000, "color": "red"}
  ]
}
```

**Resource Usage** (percentage):

```json
"thresholds": {
  "steps": [
    {"value": null, "color": "green"},
    {"value": 70, "color": "yellow"},
    {"value": 85, "color": "red"}
  ]
}
```

**Inverted** (uptime - higher is better):

```json
"thresholds": {
  "steps": [
    {"value": null, "color": "red"},
    {"value": 95, "color": "yellow"},
    {"value": 99, "color": "green"}
  ]
}
```

---

## Units and Formatting

### Common Units

**Time**:
- `ms` - Milliseconds
- `s` - Seconds
- `m` - Minutes
- `h` - Hours

**Data**:
- `bytes` - Bytes (auto-scales to KB, MB, GB)
- `Bps` - Bytes per second
- `KBs` - Kilobytes per second
- `MBs` - Megabytes per second

**Throughput**:
- `reqps` - Requests per second
- `rps` - Reads per second
- `wps` - Writes per second
- `short` - General count with K/M/B suffixes

**Percentage**:
- `percent` - 0-100
- `percentunit` - 0-1 (displayed as 0-100%)

**Custom Format**:

```json
"fieldConfig": {
  "defaults": {
    "unit": "ms",
    "decimals": 2,
    "displayName": "Response Time"
  }
}
```

---

## Layout Best Practices

### Dashboard Organization Principles

**1. Top-to-Bottom Information Hierarchy**

```
High-level KPIs (stat panels)
    ↓
Detailed time series (trends)
    ↓
Logs and traces (investigation)
```

**2. Left-to-Right Data Flow**

For services with data flow (e.g., api → worker → db):

```
┌─────────┬─────────┬─────────┐
│  API    │ Worker  │   DB    │  Match flow
│ Metrics │ Metrics │ Metrics │
└─────────┴─────────┴─────────┘
```

**3. Consistent Row Heights**

```
# Good
All stat panels: h=4
All time series: h=8
All logs panels: h=10

# Bad (inconsistent)
Random heights: h=3, h=7, h=12
```

**4. Standard Grid Widths**

```
Full width:  w=24 (one panel)
Half width:  w=12 (two panels)
Third width: w=8  (three panels)
Quarter:     w=6  (four panels)
```

### Panel Sizing Guidelines

**Stat Panels**: 4-6 grid units high
**Time Series**: 8-10 grid units high (readable)
**Logs**: 10-12 grid units high (more log lines visible)
**Tables**: 8-12 grid units (depends on row count)

---

## Variable Best Practices

### Essential Variables

**1. Datasource Selector**:

```json
{
  "name": "datasource",
  "type": "datasource",
  "query": "prometheus",
  "current": {
    "text": "Mimir-Prometheus",
    "value": "Mimir-Prometheus"
  }
}
```

**2. Service/Job Selector**:

```json
{
  "name": "service",
  "type": "query",
  "label": "Service",
  "datasource": {"type": "prometheus", "uid": "${datasource}"},
  "query": "label_values(http_requests_total, service)",
  "refresh": 2,
  "multi": true,
  "includeAll": true,
  "allValue": ".*"
}
```

**3. Environment Selector**:

```json
{
  "name": "environment",
  "type": "custom",
  "label": "Environment",
  "query": "dev,staging,prod",
  "current": {
    "text": "prod",
    "value": "prod"
  }
}
```

### Variable Usage Patterns

**In Queries**:

```promql
# Single-select
http_requests_total{service="$service"}

# Multi-select (regex)
http_requests_total{service=~"$service"}

# All option
http_requests_total{service=~"${service:regex}"}
```

**In Panel Titles**:

```json
"title": "$service - Request Rate"
"title": "Request Rate ($environment)"
```

**Chained Variables**:

```json
// Variable 1: Namespace
{
  "name": "namespace",
  "query": "label_values(namespace)"
}

// Variable 2: Service (depends on namespace)
{
  "name": "service",
  "query": "label_values(http_requests_total{namespace=\"$namespace\"}, service)"
}
```

---

## Dashboard Management Maturity

### Low Maturity (Default State)

**Characteristics**:
- Everyone can modify dashboards
- No naming conventions
- Duplicate dashboards ("copy of API dashboard 3")
- No organization or folders
- Mixed time ranges and refresh rates

### Medium Maturity

**Improvements**:
- Folder organization
- Naming conventions
- Template dashboards for common patterns
- Some provisioning
- Dashboard permissions

### High Maturity

**Achieved**:
- All dashboards provisioned as code
- Consistent design patterns (RED, USE)
- Automated testing of dashboard queries
- Version control and CI/CD
- Documentation and runbooks linked
- Dashboard-driven alerting

---

## Common Anti-Patterns

### 1. Too Many Panels

**Bad**: 50+ panels on one dashboard (slow, overwhelming)
**Good**: 10-15 panels focused on specific use case

**Solution**: Create multiple focused dashboards with links

### 2. Inconsistent Time Ranges

**Bad**: Some panels showing 5m, others 1h, others 24h
**Good**: All panels use dashboard time range

### 3. Missing Context

**Bad**: Panel titled "Error Rate" (which service? which endpoint?)
**Good**: "API Error Rate by Endpoint"

### 4. Poor Color Choices

**Bad**: Green for errors, red for success
**Good**: Consistent semantic colors

### 5. No Thresholds

**Bad**: Stat panels with no thresholds (no context)
**Good**: Meaningful thresholds based on SLOs

---

## Testing Dashboard Queries

### Performance Testing

```bash
# Test PromQL query performance
curl -G http://localhost:9009/prometheus/api/v1/query \
  --data-urlencode 'query=sum(rate(http_requests_total[5m]))' \
  --data-urlencode 'time=2024-01-01T00:00:00Z'

# Test LogQL query
curl -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="api"}' \
  --data-urlencode 'start=1640995200' \
  --data-urlencode 'end=1641081600'
```

### Query Validation

**Checklist**:
- Query returns data in expected time range
- Legend format is meaningful
- Units are correct
- Rate windows match scrape interval (5m minimum for 15s scrapes)
- No high cardinality label explosions

---

## Reference

**Official Documentation**:
- Panel types: https://grafana.com/docs/grafana/latest/panels-visualizations/visualizations/
- Time series: https://grafana.com/docs/grafana/latest/panels-visualizations/visualizations/time-series/
- Best practices: https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/
- RED method: https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/

**Dashboard Examples**:
- Grafana Dashboard Library: https://grafana.com/grafana/dashboards/
- RED metrics template: Dashboard ID 11074
- Node Exporter Full: Dashboard ID 1860

**Current Project**:
- Grafana: http://localhost:3000
- Default credentials: admin/admin
