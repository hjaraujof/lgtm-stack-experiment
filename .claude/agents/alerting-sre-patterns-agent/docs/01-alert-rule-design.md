# Alert Rule Design: LogQL and PromQL Patterns

**Created:** 2025-11-28
**Purpose:** Comprehensive guide to designing effective alert rules for Loki and Mimir

---

## Table of Contents

1. [Alert Rule Fundamentals](#alert-rule-fundamentals)
2. [LogQL Alert Patterns (Loki)](#logql-alert-patterns-loki)
3. [PromQL Alert Patterns (Mimir)](#promql-alert-patterns-mimir)
4. [Alert Configuration Structure](#alert-configuration-structure)
5. [Duration and Threshold Configuration](#duration-and-threshold-configuration)
6. [Annotations and Labels Best Practices](#annotations-and-labels-best-practices)
7. [Alert State Management](#alert-state-management)

---

## Alert Rule Fundamentals

### Core Components

Every alert rule contains these essential elements:

1. **Expression**: Query defining what to measure (LogQL for Loki, PromQL for Mimir)
2. **Condition**: Threshold that triggers the alert
3. **Duration** (`for` clause): How long condition must persist before firing
4. **Labels**: Metadata for routing, grouping, and filtering
5. **Annotations**: Human-readable descriptions, runbooks, and summaries

### Rule Types

**Alerting Rules**: Evaluate expressions periodically and trigger notifications when conditions are met.

**Recording Rules**: Pre-compute expensive queries and store results as new time series, reducing query load and improving dashboard performance.

---

## LogQL Alert Patterns (Loki)

### High Error Rate Detection

Monitor error rates from logs with ratio calculations:

```yaml
- alert: HighPercentageError
  expr: |
    sum(rate({app="foo", env="production"} |= "error" [5m])) by (job)
      /
    sum(rate({app="foo", env="production"}[5m])) by (job)
      > 0.05
  for: 10m
  labels:
    severity: page
    team: platform
  annotations:
    summary: "High error rate detected for {{ $labels.job }}"
    description: "Error rate is {{ $value | humanizePercentage }} for job {{ $labels.job }}"
    runbook_url: "https://wiki.example.com/runbooks/high-error-rate"
```

**Key aspects:**
- Uses `|=` for log line filtering (contains "error")
- Calculates ratio of error logs to total logs
- 5-minute rate window for responsive detection
- 10-minute `for` clause to avoid flapping

### Credential Leak Detection

Event-based alerting for security incidents:

```yaml
- alert: CredentialLeakDetected
  expr: |
    count_over_time({app="api-gateway"}
      |~ "(password|api_key|token)\\s*[:=]\\s*['\"]?\\w{8,}"
      [5m]) > 0
  for: 1m
  labels:
    severity: critical
    team: security
    priority: p1
  annotations:
    summary: "SECURITY: Potential credential leak in {{ $labels.app }}"
    description: "Detected {{ $value }} potential credential exposures in logs"
    runbook_url: "https://wiki.example.com/security/credential-leak-response"
    pagerduty_key: "security-critical"
```

**Key aspects:**
- Uses `|~` for regex matching
- Looks for patterns like `password=xyz123`
- Very short `for` duration (1m) due to security criticality
- Multiple labels for routing to security team

### Application Startup Failure

Detect services that fail to start properly:

```yaml
- alert: ApplicationStartupFailure
  expr: |
    sum by (service, namespace) (
      count_over_time({namespace="production"}
        |= "FATAL"
        |= "startup"
        [2m])
    ) > 3
  for: 30s
  labels:
    severity: page
    team: platform
  annotations:
    summary: "Service {{ $labels.service }} failing to start in {{ $labels.namespace }}"
    description: "{{ $value }} FATAL startup errors detected"
    runbook_url: "https://wiki.example.com/runbooks/startup-failure"
```

**Key aspects:**
- Combines multiple log line filters with `|=`
- Short time window (2m) for startup failures
- Groups by service and namespace
- Low threshold (3 errors) for quick detection

### High Log Volume (DDoS/Attack Detection)

Detect abnormal log volume indicating potential attacks:

```yaml
- alert: AbnormalLogVolume
  expr: |
    sum(rate({namespace="production", app="api-gateway"}[5m])) by (instance)
      > 1000
  for: 5m
  labels:
    severity: warning
    team: platform
  annotations:
    summary: "Abnormal log volume on {{ $labels.instance }}"
    description: "{{ $labels.instance }} generating {{ $value }} logs/sec"
    runbook_url: "https://wiki.example.com/runbooks/log-volume-spike"
```

**Key aspects:**
- Monitors raw log volume without content filtering
- Useful for detecting DDoS or brute-force attacks
- Groups by instance to identify specific targets

### Slow Query Detection

Extract and alert on slow database queries from logs:

```yaml
- alert: SlowDatabaseQueries
  expr: |
    sum by (database, query_type) (
      rate({app="database-proxy"}
        | json
        | duration > 5s
        [10m])
    ) > 0.1
  for: 5m
  labels:
    severity: warning
    team: database
  annotations:
    summary: "Slow queries detected in {{ $labels.database }}"
    description: "{{ $value }} slow queries/sec for {{ $labels.query_type }}"
    runbook_url: "https://wiki.example.com/runbooks/slow-queries"
```

**Key aspects:**
- Uses `| json` parser to extract structured fields
- Filters on numeric field (`duration > 5s`)
- Detects sustained slow query patterns

---

## PromQL Alert Patterns (Mimir)

### High Request Latency

Monitor service latency using histogram metrics:

```yaml
- alert: HighRequestLatency
  expr: |
    histogram_quantile(0.99,
      sum(rate(http_request_duration_seconds_bucket{job="api"}[5m])) by (le, service)
    ) > 1.0
  for: 10m
  labels:
    severity: page
    team: platform
  annotations:
    summary: "High request latency for {{ $labels.service }}"
    description: "P99 latency is {{ $value }}s for {{ $labels.service }}"
    runbook_url: "https://wiki.example.com/runbooks/high-latency"
```

**Key aspects:**
- Uses `histogram_quantile()` for percentile calculation
- Monitors 99th percentile (P99) latency
- 10-minute duration prevents flapping from transient spikes

### High Error Rate (4xx/5xx)

Detect elevated HTTP error rates:

```yaml
- alert: HighHTTPErrorRate
  expr: |
    sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
      > 0.05
  for: 5m
  labels:
    severity: page
    team: platform
  annotations:
    summary: "High 5xx error rate for {{ $labels.service }}"
    description: "Error rate is {{ $value | humanizePercentage }} for {{ $labels.service }}"
    runbook_url: "https://wiki.example.com/runbooks/high-error-rate"
```

**Key aspects:**
- Uses regex matching `status=~"5.."` for 500-599 codes
- Calculates ratio of errors to total requests
- 5% threshold is common starting point

### High Memory Usage

Alert on containers approaching memory limits:

```yaml
- alert: HighMemoryUsage
  expr: |
    (
      container_memory_usage_bytes{container!=""}
        /
      container_spec_memory_limit_bytes{container!=""}
    ) > 0.85
  for: 10m
  labels:
    severity: warning
    team: platform
  annotations:
    summary: "High memory usage for {{ $labels.container }}"
    description: "{{ $labels.container }} using {{ $value | humanizePercentage }} of memory limit"
    runbook_url: "https://wiki.example.com/runbooks/high-memory"
```

**Key aspects:**
- Calculates percentage of limit used
- 85% threshold provides early warning before OOM
- Filters empty container names with `container!=""`

### Service Instance Down

Detect when service instances become unreachable:

```yaml
- alert: InstanceDown
  expr: up{job="api"} == 0
  for: 5m
  labels:
    severity: critical
    team: platform
    priority: p1
  annotations:
    summary: "Instance {{ $labels.instance }} is down"
    description: "{{ $labels.job }} on {{ $labels.instance }} has been down for more than 5 minutes"
    runbook_url: "https://wiki.example.com/runbooks/instance-down"
```

**Key aspects:**
- Uses `up` metric (automatically generated by Prometheus)
- Simple equality check (`== 0`)
- Critical severity as it indicates complete outage

### High CPU Throttling

Detect containers being CPU throttled:

```yaml
- alert: HighCPUThrottling
  expr: |
    rate(container_cpu_cfs_throttled_seconds_total[5m])
      /
    rate(container_cpu_cfs_periods_total[5m])
      > 0.25
  for: 15m
  labels:
    severity: warning
    team: platform
  annotations:
    summary: "High CPU throttling for {{ $labels.container }}"
    description: "{{ $labels.container }} throttled {{ $value | humanizePercentage }} of the time"
    runbook_url: "https://wiki.example.com/runbooks/cpu-throttling"
```

**Key aspects:**
- Calculates percentage of time being throttled
- 25% threshold indicates significant performance impact
- Longer duration (15m) as CPU throttling is often temporary

### Disk Space Running Low

Alert on filling disk space:

```yaml
- alert: DiskSpaceRunningLow
  expr: |
    (
      node_filesystem_avail_bytes{fstype!~"tmpfs|fuse.lxcfs"}
        /
      node_filesystem_size_bytes{fstype!~"tmpfs|fuse.lxcfs"}
    ) < 0.15
  for: 5m
  labels:
    severity: warning
    team: infrastructure
  annotations:
    summary: "Low disk space on {{ $labels.instance }}"
    description: "{{ $labels.mountpoint }} has {{ $value | humanizePercentage }} space remaining"
    runbook_url: "https://wiki.example.com/runbooks/disk-space"
```

**Key aspects:**
- Excludes temporary filesystems with `fstype!~`
- 15% remaining threshold provides time to respond
- Groups by mountpoint for specific filesystem identification

---

## Alert Configuration Structure

### Rule Group Organization

Rules are organized into groups for efficient evaluation:

```yaml
groups:
  - name: api-availability
    interval: 30s  # How often to evaluate rules in this group
    limit: 0       # Max alerts per rule (0 = unlimited)
    rules:
      - alert: HighErrorRate
        expr: ...
      - alert: HighLatency
        expr: ...

  - name: infrastructure-health
    interval: 1m
    rules:
      - alert: HighMemory
        expr: ...
      - alert: DiskSpaceLow
        expr: ...
```

**Best practices:**
- Group related alerts together
- Use appropriate intervals (faster for critical metrics)
- Name groups descriptively

### Loki Ruler Configuration

In `/config/loki-config.yaml`:

```yaml
ruler:
  alertmanager_url: 'http://alertmanager:9093'
  ring:
    kvstore:
      store: inmemory
  rule_path: /loki/rules-temp
  storage:
    type: local
    local:
      directory: /loki/rules
  enable_api: true
```

### Mimir Ruler Configuration

In `/config/mimir-config.yaml`:

```yaml
ruler:
  rule_path: /data/mimir-rules
  alertmanager_url: http://localhost:9009/alertmanager
  ring:
    kvstore:
      store: inmemory

ruler_storage:
  backend: filesystem
  filesystem:
    dir: /data/mimir-ruler-storage
```

---

## Duration and Threshold Configuration

### The `for` Clause

The `for` clause determines how long a condition must be true before an alert fires:

```yaml
- alert: Example
  expr: metric > threshold
  for: 5m  # Condition must be true for 5 consecutive minutes
```

**When to use `for`:**
- **Short duration (1-5m)**: For stable metrics with consistent values
- **Medium duration (5-15m)**: For metrics with occasional spikes
- **Long duration (15m+)**: For noisy metrics or gradual degradation

**When to skip `for`:**
- Security incidents (immediate response needed)
- Complete outages (no false positive risk)
- Event-based alerts (log pattern detection)

### The `keep_firing_for` Clause

Maintains alert state after condition clears (prevents flapping):

```yaml
- alert: FlappingService
  expr: service_up == 0
  for: 2m
  keep_firing_for: 5m  # Keep alert active for 5m after recovery
  labels:
    severity: warning
  annotations:
    summary: "Service experiencing flapping"
```

**Use cases:**
- Services with rapid restart cycles
- Network connectivity issues causing intermittent failures
- Alert fatigue reduction

### Threshold Selection Guidelines

**Error Rates:**
- **Critical**: > 5% errors (significant user impact)
- **Warning**: > 1% errors (degraded experience)
- **Informational**: > 0.1% errors (early indicator)

**Latency (P99):**
- **Critical**: > 2x target latency
- **Warning**: > 1.5x target latency
- **Informational**: > 1.2x target latency

**Resource Usage:**
- **Critical**: > 95% utilization (imminent failure)
- **Warning**: > 85% utilization (degraded performance)
- **Informational**: > 75% utilization (trending concern)

---

## Annotations and Labels Best Practices

### Required Labels

```yaml
labels:
  severity: critical | page | warning | info
  team: platform | database | security | frontend
  component: api | ingester | querier | compactor
  environment: production | staging | development
```

**Severity levels:**
- **critical**: P1 incident, immediate page
- **page**: P2 incident, page during business hours
- **warning**: P3 incident, create ticket
- **info**: Informational, monitoring only

### Essential Annotations

```yaml
annotations:
  summary: "Brief one-line description"
  description: "Detailed multi-line explanation with context"
  runbook_url: "https://wiki.example.com/runbooks/alert-name"
  dashboard_url: "https://grafana.example.com/d/dashboard-id"
  team_slack: "#team-platform"
```

### Templating in Annotations

Use Go template syntax to include dynamic values:

```yaml
annotations:
  summary: "High error rate on {{ $labels.service }}"
  description: |
    Service: {{ $labels.service }}
    Error Rate: {{ $value | humanizePercentage }}
    Instance: {{ $labels.instance }}

    Current error rate exceeds 5% threshold.
    Check dashboard: {{ $labels.dashboard_url }}
  runbook_url: "https://wiki.example.com/runbooks/{{ $labels.service }}/high-error-rate"
```

**Available template variables:**
- `{{ $labels.labelname }}`: Access any label value
- `{{ $value }}`: Current numeric value of the metric
- `{{ $externalLabels }}`: External labels from Prometheus config

**Template functions:**
- `{{ $value | humanizePercentage }}`: Format as percentage (0.05 → 5%)
- `{{ $value | humanize }}`: Format large numbers (1000000 → 1M)
- `{{ $value | humanizeDuration }}`: Format seconds (3600 → 1h)

### Label vs Annotation Decision

**Use labels for:**
- Routing decisions (team, severity, component)
- Grouping alerts
- Filtering in Alertmanager
- Must be static or low cardinality

**Use annotations for:**
- Human-readable descriptions
- URLs and links
- Detailed context
- Can be high cardinality or dynamic

---

## Alert State Management

### Alert Lifecycle

```
Inactive → Pending → Firing → Resolved
```

**Inactive**: Condition evaluates to false or no results

**Pending**: Condition is true but hasn't met `for` duration
- Alert exists but doesn't send notifications
- Visible in Prometheus UI under "Inactive" tab

**Firing**: Condition true for entire `for` duration
- Notifications sent to Alertmanager
- Appears in "Active" tab

**Resolved**: Condition becomes false after firing
- Resolution notification sent (if configured)
- Alert removed from active list

### State Tracking in Prometheus

Prometheus creates synthetic time series for alerts:

```promql
ALERTS{alertname="HighErrorRate", alertstate="pending", ...} = 1
ALERTS{alertname="HighErrorRate", alertstate="firing", ...} = 1
```

**Use for:**
- Creating meta-alerts (alerts about alerts)
- Dashboards showing alert history
- Analysis of alert frequency

Example query to count firing alerts:

```promql
sum(ALERTS{alertstate="firing"}) by (alertname)
```

### Best Practices

1. **Start conservative**: Higher thresholds and longer durations initially
2. **Iterate based on feedback**: Adjust after observing real alert behavior
3. **Reduce alert fatigue**: Use `for` and `keep_firing_for` to prevent flapping
4. **Group related alerts**: Use inhibition rules in Alertmanager
5. **Include context**: Rich annotations help on-call engineers respond faster
6. **Test alerts**: Verify alerts fire correctly before deploying to production
7. **Document runbooks**: Every alert should have a runbook_url
8. **Review regularly**: Remove or adjust alerts that generate too many false positives

---

## References

- [Prometheus Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Grafana Loki Alerting](https://grafana.com/docs/loki/latest/alert/)
- [Grafana Mimir Ruler](https://grafana.com/docs/mimir/latest/references/architecture/components/ruler/)
- [Google SRE Workbook: Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
