# Grafana Dashboard Provisioning

**Purpose**: Comprehensive guide for dashboard JSON structure, provisioning configuration, and GitOps management.

**Last Updated**: 2025-11-28

---

## Overview

Grafana dashboards can be:
1. **Created manually** in the UI (not recommended for production)
2. **Provisioned from files** (recommended - version controlled, reproducible)

This guide focuses on dashboard provisioning patterns for infrastructure as code.

---

## Dashboard Provisioning Basics

### Configuration Structure

```
config/grafana/provisioning/
├── dashboards/
│   ├── dashboard-config.yaml    # Provisioning configuration
│   └── dashboards/              # Dashboard JSON files
│       ├── system-overview.json
│       ├── service-red-metrics.json
│       └── lgtm-stack-health.json
```

### Provider Configuration

**File**: `provisioning/dashboards/dashboard-config.yaml`

```yaml
apiVersion: 1

providers:
  - name: 'Default Dashboards'
    orgId: 1
    folder: 'System Monitoring'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: true
```

**Configuration Fields**:

- **name** - Provider display name
- **orgId** - Organization ID (1 for default org)
- **folder** - Target folder in Grafana (created if missing)
- **type** - Always `file` for file-based provisioning
- **disableDeletion** - Prevent dashboard deletion via UI
- **updateIntervalSeconds** - Check for file changes interval (default: 30s)
- **allowUiUpdates** - Allow editing provisioned dashboards in UI
- **options.path** - Directory containing dashboard JSON files
- **options.foldersFromFilesStructure** - Mirror filesystem folders in Grafana

### Folder Structure Options

**Option 1: Single Folder** (foldersFromFilesStructure: false)

```
dashboards/
├── dashboard-config.yaml
└── dashboards/
    ├── dashboard1.json
    ├── dashboard2.json
    └── dashboard3.json
```

All dashboards go to the folder specified in `folder: 'System Monitoring'`.

**Option 2: Nested Folders** (foldersFromFilesStructure: true)

```
dashboards/
├── dashboard-config.yaml
└── dashboards/
    ├── services/
    │   ├── api-metrics.json
    │   └── worker-metrics.json
    ├── infrastructure/
    │   ├── nodes.json
    │   └── network.json
    └── business/
        └── revenue.json
```

Grafana creates folders matching filesystem structure:
- `System Monitoring/services/`
- `System Monitoring/infrastructure/`
- `System Monitoring/business/`

### Hot Reload vs. Restart

**Hot Reload** (no restart required):
- Grafana checks for changes every `updateIntervalSeconds`
- Updates existing dashboards automatically
- **Limitation**: Doesn't detect new files or deletions

**Restart** (full reload):
- Processes all dashboard files
- Detects new files and deletions
- Required for major configuration changes

---

## Dashboard JSON Structure

### Complete Dashboard Template

```json
{
  "uid": "service-overview-uid",
  "title": "Service Overview",
  "tags": ["service", "red-metrics", "production"],
  "timezone": "browser",
  "schemaVersion": 38,
  "version": 1,
  "refresh": "30s",
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "timepicker": {
    "refresh_intervals": ["5s", "10s", "30s", "1m", "5m", "15m", "30m", "1h", "2h", "1d"]
  },
  "annotations": {
    "list": [
      {
        "datasource": {
          "type": "loki",
          "uid": "Loki"
        },
        "enable": true,
        "expr": "{job=\"my-service\"} |= \"deployment\"",
        "iconColor": "red",
        "name": "Deployments",
        "tagKeys": "job",
        "textFormat": "Deployment: {{msg}}",
        "titleFormat": "Deployment"
      }
    ]
  },
  "templating": {
    "list": [
      {
        "name": "datasource",
        "type": "datasource",
        "query": "prometheus",
        "current": {
          "selected": false,
          "text": "Mimir-Prometheus",
          "value": "Mimir-Prometheus"
        }
      },
      {
        "name": "service",
        "type": "query",
        "datasource": {
          "type": "prometheus",
          "uid": "${datasource}"
        },
        "query": "label_values(http_requests_total, service)",
        "refresh": 2,
        "multi": true,
        "includeAll": true,
        "allValue": ".*"
      }
    ]
  },
  "panels": [
    {
      "id": 1,
      "type": "timeseries",
      "title": "Request Rate",
      "gridPos": {
        "x": 0,
        "y": 0,
        "w": 12,
        "h": 8
      },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{service=~\"$service\"}[5m])) by (service)",
          "legendFormat": "{{service}}",
          "refId": "A"
        }
      ],
      "options": {
        "legend": {
          "displayMode": "table",
          "placement": "right",
          "calcs": ["mean", "lastNotNull"]
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
            "fillOpacity": 10
          }
        }
      }
    }
  ]
}
```

### Key Dashboard Fields

**Metadata**:
- **uid** - Unique dashboard identifier (used for updates)
- **title** - Dashboard name
- **tags** - Searchable tags
- **version** - Dashboard version (auto-incremented)
- **schemaVersion** - Grafana schema version (current: 38)

**Time Settings**:
- **timezone** - `browser`, `utc`, or specific timezone
- **refresh** - Auto-refresh interval (`30s`, `1m`, `5m`, etc.)
- **time.from** - Default time range start (`now-6h`, `now-24h`, `now-7d`)
- **time.to** - Default time range end (usually `now`)

**UID Management**:

```json
// Include UID to update existing dashboard
"uid": "my-dashboard-uid"

// Omit UID to auto-generate (creates new dashboard each time)
// "uid": "..." // Don't include
```

**Best Practice**: Always include a meaningful UID for provisioned dashboards.

---

## Panel Configuration

### Panel Structure

```json
{
  "id": 1,
  "type": "timeseries",
  "title": "Panel Title",
  "description": "Panel description shown on hover",
  "gridPos": {
    "x": 0,
    "y": 0,
    "w": 12,
    "h": 8
  },
  "targets": [...],
  "options": {...},
  "fieldConfig": {...}
}
```

### Grid Layout (gridPos)

Grafana uses a 24-column grid system:

```json
"gridPos": {
  "x": 0,    // Horizontal position (0-23)
  "y": 0,    // Vertical position (0-infinity)
  "w": 12,   // Width in columns (1-24)
  "h": 8     // Height in grid units (1 unit = 30px)
}
```

**Common Layouts**:

```
┌─────────────┬─────────────┐
│  w=12, h=8  │  w=12, h=8  │  Full width: 2 panels
│  x=0, y=0   │  x=12, y=0  │
└─────────────┴─────────────┘

┌────────┬────────┬────────┐
│  w=8   │  w=8   │  w=8   │  Three equal panels
│  h=6   │  h=6   │  h=6   │
└────────┴────────┴────────┘

┌──────────────────────────┐
│      w=24, h=4           │  Full-width header
├────────┬─────────────────┤
│  w=8   │     w=16        │  Sidebar + main
│  h=10  │     h=10        │
└────────┴─────────────────┘
```

### Panel Types

**Time Series** (most common):

```json
{
  "type": "timeseries",
  "options": {
    "tooltip": {
      "mode": "multi",
      "sort": "desc"
    },
    "legend": {
      "displayMode": "table",
      "placement": "right",
      "calcs": ["mean", "lastNotNull", "max"]
    }
  },
  "fieldConfig": {
    "defaults": {
      "unit": "reqps",
      "color": {"mode": "palette-classic"},
      "custom": {
        "lineWidth": 2,
        "fillOpacity": 10,
        "pointSize": 5,
        "lineInterpolation": "smooth"
      },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"value": null, "color": "green"},
          {"value": 80, "color": "yellow"},
          {"value": 90, "color": "red"}
        ]
      }
    }
  }
}
```

**Logs Panel**:

```json
{
  "type": "logs",
  "options": {
    "showTime": true,
    "showLabels": true,
    "showCommonLabels": false,
    "wrapLogMessage": false,
    "prettifyLogMessage": true,
    "enableLogDetails": true,
    "dedupStrategy": "none",
    "sortOrder": "Descending"
  },
  "targets": [
    {
      "datasource": {"type": "loki", "uid": "Loki"},
      "expr": "{job=\"my-service\"} |= \"error\"",
      "refId": "A"
    }
  ]
}
```

**Traces Panel**:

```json
{
  "type": "traces",
  "targets": [
    {
      "datasource": {"type": "tempo", "uid": "tempo"},
      "queryType": "traceql",
      "query": "{ service.name=\"my-service\" && duration > 1s }",
      "refId": "A"
    }
  ]
}
```

**Node Graph** (service map):

```json
{
  "type": "nodeGraph",
  "targets": [
    {
      "datasource": {"type": "tempo", "uid": "tempo"},
      "queryType": "serviceMap",
      "refId": "A"
    }
  ]
}
```

**Stat Panel** (single value):

```json
{
  "type": "stat",
  "options": {
    "graphMode": "area",
    "colorMode": "value",
    "orientation": "auto",
    "textMode": "auto",
    "reduceOptions": {
      "values": false,
      "calcs": ["lastNotNull"]
    }
  },
  "fieldConfig": {
    "defaults": {
      "unit": "short",
      "thresholds": {
        "mode": "absolute",
        "steps": [
          {"value": null, "color": "green"},
          {"value": 5, "color": "red"}
        ]
      }
    }
  }
}
```

---

## Template Variables

### Variable Types

**1. Datasource Variable**:

```json
{
  "name": "datasource",
  "type": "datasource",
  "query": "prometheus",
  "current": {
    "selected": false,
    "text": "Mimir-Prometheus",
    "value": "Mimir-Prometheus"
  }
}
```

**2. Query Variable** (Prometheus):

```json
{
  "name": "service",
  "label": "Service",
  "type": "query",
  "datasource": {
    "type": "prometheus",
    "uid": "${datasource}"
  },
  "query": "label_values(http_requests_total, service)",
  "refresh": 2,  // On dashboard load and time range change
  "multi": true,
  "includeAll": true,
  "allValue": ".*",
  "sort": 1  // Alphabetical ascending
}
```

**3. Query Variable** (Loki):

```json
{
  "name": "namespace",
  "type": "query",
  "datasource": {
    "type": "loki",
    "uid": "Loki"
  },
  "query": "label_values(namespace)",
  "refresh": 1  // On dashboard load
}
```

**4. Custom Variable**:

```json
{
  "name": "environment",
  "type": "custom",
  "query": "dev,staging,prod",
  "multi": false,
  "includeAll": false,
  "current": {
    "selected": true,
    "text": "prod",
    "value": "prod"
  }
}
```

**5. Constant Variable** (hidden):

```json
{
  "name": "cluster_id",
  "type": "constant",
  "query": "prod-us-east-1",
  "hide": 2  // Hide variable in dashboard
}
```

### Variable Usage in Queries

**PromQL**:

```promql
# Single-select variable
http_requests_total{service="$service"}

# Multi-select variable with regex
http_requests_total{service=~"$service"}

# All option with custom allValue
http_requests_total{service=~"${service:pipe}"}
```

**LogQL**:

```logql
# Single-select
{namespace="$namespace", job="$job"}

# Multi-select
{namespace=~"$namespace", job=~"$job"}
```

**TraceQL**:

```traceql
{ service.name="${service}" && duration > ${min_duration}s }
```

### Variable Options

**refresh**:
- `0` - Never
- `1` - On dashboard load
- `2` - On time range change

**sort**:
- `0` - Disabled
- `1` - Alphabetical ascending
- `2` - Alphabetical descending
- `3` - Numerical ascending
- `4` - Numerical descending
- `5` - Alphabetical case-insensitive

**multi**: Allow selecting multiple values
**includeAll**: Add "All" option
**allValue**: Value used when "All" selected (e.g., `.*` for regex)

---

## Annotations

Annotations display events on time series graphs:

```json
"annotations": {
  "list": [
    {
      "name": "Deployments",
      "enable": true,
      "datasource": {
        "type": "loki",
        "uid": "Loki"
      },
      "expr": "{job=\"deployment-tracker\"} |= \"deployed\"",
      "tagKeys": "service,version",
      "textFormat": "{{service}} {{version}}",
      "titleFormat": "Deployment",
      "iconColor": "red",
      "step": "1m"
    }
  ]
}
```

**Configuration**:

- **expr** - LogQL/PromQL query
- **tagKeys** - Labels to extract from logs (comma-separated)
- **textFormat** - Annotation text using `{{label}}`
- **titleFormat** - Annotation title
- **iconColor** - Marker color on graph
- **step** - Query resolution

---

## Rows (Dashboard Organization)

Group related panels using rows:

```json
"panels": [
  {
    "type": "row",
    "title": "Request Metrics",
    "collapsed": false,
    "gridPos": {"x": 0, "y": 0, "w": 24, "h": 1},
    "panels": []
  },
  {
    "type": "timeseries",
    "title": "Request Rate",
    "gridPos": {"x": 0, "y": 1, "w": 12, "h": 8}
  },
  {
    "type": "timeseries",
    "title": "Error Rate",
    "gridPos": {"x": 12, "y": 1, "w": 12, "h": 8}
  },
  {
    "type": "row",
    "title": "Latency Metrics",
    "collapsed": false,
    "gridPos": {"x": 0, "y": 9, "w": 24, "h": 1},
    "panels": []
  }
]
```

**Collapsible Rows**:

```json
{
  "type": "row",
  "title": "Advanced Metrics",
  "collapsed": true,
  "panels": [
    // Panels inside collapsed row
  ]
}
```

---

## Export and Import Workflow

### Exporting Dashboards

**From Grafana UI**:

1. Open dashboard
2. Click "Share" icon (top right)
3. Select "Export" tab
4. Toggle "Export for sharing externally"
5. Click "Save to file"

**Remove Dynamic Fields**:

```bash
# Remove id, version, and iteration fields
jq 'del(.id, .version, .iteration)' dashboard.json > dashboard-clean.json
```

**Set/Update UID**:

```bash
# Add or update UID
jq '.uid = "my-dashboard-uid"' dashboard.json > dashboard-with-uid.json
```

### Importing Dashboards

**Via Provisioning** (recommended):

1. Place JSON file in provisioning directory
2. Ensure UID is set
3. Restart Grafana or wait for hot reload

**Via UI**:

1. Dashboards > Import
2. Upload JSON file or paste JSON
3. Select datasources
4. Click "Import"

---

## Dashboard Linking

### Link to Dashboard

```json
"links": [
  {
    "title": "Service Details",
    "type": "dashboard",
    "icon": "external link",
    "tags": ["service", "details"],
    "targetBlank": true,
    "url": "/d/service-details-uid?var-service=$service&$__all_variables",
    "keepTime": true
  }
]
```

**Variables in Links**:
- `$service` - Pass variable value
- `$__all_variables` - Pass all variables
- `keepTime=true` - Preserve time range

### Link to External URL

```json
"links": [
  {
    "title": "Kibana Logs",
    "type": "link",
    "icon": "external link",
    "url": "https://kibana.example.com/app/logs?service=$service",
    "targetBlank": true
  }
]
```

---

## Common Dashboard Patterns

### RED Metrics Dashboard

```json
{
  "title": "Service RED Metrics",
  "uid": "service-red-metrics",
  "panels": [
    {
      "type": "stat",
      "title": "Request Rate",
      "gridPos": {"x": 0, "y": 0, "w": 8, "h": 4},
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{service=\"$service\"}[5m]))",
          "refId": "A"
        }
      ]
    },
    {
      "type": "stat",
      "title": "Error Rate",
      "gridPos": {"x": 8, "y": 0, "w": 8, "h": 4},
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{service=\"$service\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{service=\"$service\"}[5m])) * 100",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "thresholds": {
            "steps": [
              {"value": null, "color": "green"},
              {"value": 1, "color": "yellow"},
              {"value": 5, "color": "red"}
            ]
          }
        }
      }
    },
    {
      "type": "stat",
      "title": "P95 Latency",
      "gridPos": {"x": 16, "y": 0, "w": 8, "h": 4},
      "targets": [
        {
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        }
      }
    },
    {
      "type": "timeseries",
      "title": "Request Rate Over Time",
      "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8},
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{service=\"$service\"}[5m])) by (status)",
          "legendFormat": "{{status}}",
          "refId": "A"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Latency Distribution",
      "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8},
      "targets": [
        {
          "expr": "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
          "legendFormat": "P50",
          "refId": "A"
        },
        {
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
          "legendFormat": "P95",
          "refId": "B"
        },
        {
          "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service=\"$service\"}[5m])) by (le))",
          "legendFormat": "P99",
          "refId": "C"
        }
      ]
    }
  ]
}
```

### LGTM Stack Health Dashboard

```json
{
  "title": "LGTM Stack Health",
  "uid": "lgtm-stack-health",
  "panels": [
    {
      "type": "stat",
      "title": "Loki Ingestion Rate",
      "targets": [
        {
          "expr": "sum(rate(loki_distributor_bytes_received_total[5m]))",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": {"unit": "Bps"}
      }
    },
    {
      "type": "stat",
      "title": "Tempo Traces/sec",
      "targets": [
        {
          "expr": "sum(rate(tempo_distributor_spans_received_total[5m]))",
          "refId": "A"
        }
      ]
    },
    {
      "type": "stat",
      "title": "Mimir Series Count",
      "targets": [
        {
          "expr": "sum(cortex_ingester_memory_series)",
          "refId": "A"
        }
      ]
    }
  ]
}
```

---

## Troubleshooting

### Dashboard Not Appearing

**Solutions**:
- Check dashboard JSON is valid (use `jq . dashboard.json`)
- Verify file is in provisioning directory
- Check Grafana logs: `docker compose logs grafana`
- Restart Grafana for new files

### UID Conflicts

**Symptom**: "Dashboard with same UID already exists"

**Solutions**:
- Change UID in JSON file
- Or remove existing dashboard with conflicting UID

### Variables Not Working

**Solutions**:
- Check variable name matches usage: `$service` or `${service}`
- Verify datasource UID is correct
- Test query in Explore first
- Check refresh settings

### Datasource Not Found

**Symptom**: "Datasource not found" in panels

**Solutions**:
- Verify datasource UID matches provisioned datasource
- Use datasource reference: `{"type": "prometheus", "uid": "Mimir-Prometheus"}`
- Don't hardcode datasource IDs

---

## Best Practices

### 1. Always Use UIDs

```json
// Good
"uid": "service-overview"

// Bad - creates new dashboard each provision
// "uid": null  // Don't do this
```

### 2. Remove Dynamic Fields Before Provisioning

```bash
jq 'del(.id, .version, .iteration)' dashboard.json > clean.json
```

### 3. Use Meaningful Names

```
# Good
service-red-metrics.json
infrastructure-nodes.json
lgtm-stack-health.json

# Bad
dashboard1.json
new-dashboard-copy.json
```

### 4. Organize with Folders

```
dashboards/
├── services/
│   ├── api-metrics.json
│   └── worker-metrics.json
└── infrastructure/
    ├── nodes.json
    └── storage.json
```

### 5. Document Dashboard Purpose

```json
{
  "title": "Service RED Metrics",
  "description": "Request rate, error rate, and duration metrics for microservices. Based on Tom Wilkie's RED method.",
  "tags": ["red-metrics", "service", "production"]
}
```

### 6. Use Template Variables for Flexibility

```json
// Single dashboard for all services
"templating": {
  "list": [
    {
      "name": "service",
      "type": "query",
      "query": "label_values(http_requests_total, service)"
    }
  ]
}
```

### 7. Set Sensible Defaults

```json
"refresh": "30s",           // Auto-refresh
"time": {
  "from": "now-6h",         // Last 6 hours
  "to": "now"
},
"timezone": "browser",      // Use user's timezone
"editable": false           // Prevent accidental edits
```

---

## Reference

**Official Documentation**:
- Dashboard JSON: https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/
- Provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- Panel types: https://grafana.com/docs/grafana/latest/panels-visualizations/visualizations/

**Tools**:
- JSON formatter: `jq`
- JSON validator: https://jsonlint.com/
- Dashboard examples: https://grafana.com/grafana/dashboards/

**Current Project**:
- Provisioning config: `config/grafana/provisioning/dashboards/`
