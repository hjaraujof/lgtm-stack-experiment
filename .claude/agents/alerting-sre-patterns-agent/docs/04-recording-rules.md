# Recording Rules: Pre-Computation Patterns

**Created:** 2025-11-28
**Purpose:** Comprehensive guide to designing and implementing recording rules for performance optimization and SLO tracking

---

## Table of Contents

1. [Recording Rules Fundamentals](#recording-rules-fundamentals)
2. [Why Recording Rules?](#why-recording-rules)
3. [Naming Conventions](#naming-conventions)
4. [Common Patterns](#common-patterns)
5. [SLO Recording Rules](#slo-recording-rules)
6. [Performance Recording Rules](#performance-recording-rules)
7. [Aggregation Recording Rules](#aggregation-recording-rules)
8. [Best Practices](#best-practices)
9. [Testing and Validation](#testing-and-validation)

---

## Recording Rules Fundamentals

### Definition

Recording rules pre-compute frequently needed or computationally expensive expressions on a schedule, storing results as new time series metrics. This dramatically improves query performance for dashboards and alerts.

### Basic Structure

```yaml
groups:
  - name: group_identifier
    interval: 30s  # Evaluation frequency
    rules:
      - record: metric_name
        expr: promql_expression
        labels:
          additional_label: value
```

### When Results Appear

Recording rule results become available as regular metrics:

```promql
# Query the pre-computed metric directly
sli:http_availability:ratio_5m{service="api"}

# Use in alerts
sli:http_availability:ratio_5m < 0.999
```

---

## Why Recording Rules?

### Performance Benefits

**Without recording rule:**
```promql
# Dashboard panel queries this every 15 seconds
sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
  /
sum(rate(http_requests_total[5m])) by (service)
```

**With recording rule:**
```yaml
# Computed once every 30 seconds
- record: sli:http_availability:ratio_5m
  expr: |
    sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
```

**Dashboard query becomes:**
```promql
# Simple metric lookup - instant
sli:http_availability:ratio_5m
```

**Performance improvement:**
- **Query time**: 2000ms → 50ms (40x faster)
- **Load on storage**: Massive reduction
- **Dashboard responsiveness**: Near-instant

### Consistency Benefits

**Problem:** Multiple alerts computing the same metric slightly differently

```yaml
# Alert 1
expr: (sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) > 0.05

# Alert 2
expr: (1 - sum(rate(http_requests_total{status!~"5.."}[5m])) / sum(rate(http_requests_total[5m]))) > 0.05
```

**Solution:** Single recording rule used everywhere

```yaml
- record: slo:error_rate:5m
  expr: |
    1 - (
      sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
        /
      sum(rate(http_requests_total[5m])) by (service)
    )

# All alerts use the same definition
- alert: HighErrorRate
  expr: slo:error_rate:5m > 0.05
```

### Enabling Complex Alerting

Multi-window burn rate alerts require multiple time windows. Without recording rules, alert expressions become unmanageably complex.

**With recording rules:**
```yaml
# Simple, readable alert
expr: |
  (burn_rate:http_availability:1h > 14.4)
  and
  (burn_rate:http_availability:5m > 14.4)
```

**Without recording rules:**
```yaml
# Unreadable 50+ line expression
expr: |
  (
    (1 - (sum(rate(http_requests_total{status!~"5.."}[1h])) by (service) / sum(rate(http_requests_total[1h])) by (service)))
      /
    0.001
  ) > 14.4
  and
  (
    (1 - (sum(rate(http_requests_total{status!~"5.."}[5m])) by (service) / sum(rate(http_requests_total[5m])) by (service)))
      /
    0.001
  ) > 14.4
```

---

## Naming Conventions

### The Standard Pattern

**Format:** `level:metric:operations`

**Components:**
- **level**: Aggregation level (sli, slo, service, node, cluster)
- **metric**: Base metric name
- **operations**: What was done (ratio, sum, avg, error_rate)

### Examples

```yaml
# SLI-level metrics
sli:http_availability:ratio_5m
sli:http_latency_500ms:ratio_5m
sli:data_freshness:seconds_5m

# SLO-level metrics
slo:error_rate:5m
slo:error_budget:ratio
slo:error_budget_remaining:ratio_30d

# Burn rate metrics
burn_rate:http_availability:5m
burn_rate:http_availability:1h
burn_rate:http_availability:1d

# Service-level aggregations
service:http_requests:rate_5m
service:cpu_usage:avg_5m
service:memory_usage:bytes

# Node-level aggregations
node:cpu:usage_percent
node:memory:usage_percent
node:disk:usage_percent

# Cluster-level aggregations
cluster:http_requests:rate_5m
cluster:pods:count
cluster:capacity:percent
```

### Time Window Suffixes

Include time window in metric name for clarity:

```yaml
sli:http_availability:ratio_5m     # 5-minute window
sli:http_availability:ratio_30m    # 30-minute window
sli:http_availability:ratio_1h     # 1-hour window
sli:http_availability:ratio_6h     # 6-hour window
sli:http_availability:ratio_1d     # 1-day window
sli:http_availability:ratio_3d     # 3-day window
sli:http_availability:ratio_30d    # 30-day window (SLO period)
```

---

## Common Patterns

### Availability Ratio

Pre-compute success rate:

```yaml
- record: sli:http_availability:ratio_5m
  expr: |
    sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
```

### Error Rate

Pre-compute failure rate:

```yaml
- record: slo:error_rate:5m
  expr: |
    sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
```

**Or as inverse of availability:**

```yaml
- record: slo:error_rate:5m
  expr: 1 - sli:http_availability:ratio_5m
```

### Latency Percentiles

Pre-compute P50, P95, P99 latencies:

```yaml
- record: sli:http_latency:p50_5m
  expr: |
    histogram_quantile(0.50,
      sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
    )

- record: sli:http_latency:p95_5m
  expr: |
    histogram_quantile(0.95,
      sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
    )

- record: sli:http_latency:p99_5m
  expr: |
    histogram_quantile(0.99,
      sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
    )
```

### Request Rate

Pre-compute requests per second:

```yaml
- record: service:http_requests:rate_5m
  expr: |
    sum(rate(http_requests_total[5m])) by (service)
```

### Resource Utilization

Pre-compute CPU and memory usage percentages:

```yaml
- record: node:cpu:usage_percent
  expr: |
    100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) by (instance) * 100)

- record: node:memory:usage_percent
  expr: |
    100 * (
      1 - (
        node_memory_MemAvailable_bytes
          /
        node_memory_MemTotal_bytes
      )
    )
```

---

## SLO Recording Rules

### Complete Multi-Window SLI Set

For SLO-based alerting, pre-compute error rates across all required time windows:

```yaml
groups:
  - name: slo_sli_recording_rules
    interval: 30s
    rules:
      # ==================================
      # Availability SLI - Multiple Windows
      # ==================================

      - record: sli:http_availability:ratio_5m
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
            /
          sum(rate(http_requests_total[5m])) by (service)

      - record: sli:http_availability:ratio_30m
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[30m])) by (service)
            /
          sum(rate(http_requests_total[30m])) by (service)

      - record: sli:http_availability:ratio_1h
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[1h])) by (service)
            /
          sum(rate(http_requests_total[1h])) by (service)

      - record: sli:http_availability:ratio_2h
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[2h])) by (service)
            /
          sum(rate(http_requests_total[2h])) by (service)

      - record: sli:http_availability:ratio_6h
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[6h])) by (service)
            /
          sum(rate(http_requests_total[6h])) by (service)

      - record: sli:http_availability:ratio_1d
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[1d])) by (service)
            /
          sum(rate(http_requests_total[1d])) by (service)

      - record: sli:http_availability:ratio_3d
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[3d])) by (service)
            /
          sum(rate(http_requests_total[3d])) by (service)

      - record: sli:http_availability:ratio_30d
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[30d])) by (service)
            /
          sum(rate(http_requests_total[30d])) by (service)

      # ==================================
      # Error Rate (Inverse of Availability)
      # ==================================

      - record: slo:error_rate:5m
        expr: 1 - sli:http_availability:ratio_5m

      - record: slo:error_rate:30m
        expr: 1 - sli:http_availability:ratio_30m

      - record: slo:error_rate:1h
        expr: 1 - sli:http_availability:ratio_1h

      - record: slo:error_rate:2h
        expr: 1 - sli:http_availability:ratio_2h

      - record: slo:error_rate:6h
        expr: 1 - sli:http_availability:ratio_6h

      - record: slo:error_rate:1d
        expr: 1 - sli:http_availability:ratio_1d

      - record: slo:error_rate:3d
        expr: 1 - sli:http_availability:ratio_3d

      # ==================================
      # Error Budget Definition
      # ==================================

      - record: slo:error_budget:ratio
        expr: 0.001  # 0.1% for 99.9% SLO
        labels:
          slo_target: "99.9"

      # ==================================
      # Burn Rate Calculation
      # ==================================

      - record: burn_rate:http_availability:5m
        expr: |
          slo:error_rate:5m / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_availability:30m
        expr: |
          slo:error_rate:30m / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_availability:1h
        expr: |
          slo:error_rate:1h / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_availability:2h
        expr: |
          slo:error_rate:2h / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_availability:6h
        expr: |
          slo:error_rate:6h / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_availability:1d
        expr: |
          slo:error_rate:1d / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_availability:3d
        expr: |
          slo:error_rate:3d / ignoring(slo_target) slo:error_budget:ratio

      # ==================================
      # Error Budget Remaining
      # ==================================

      - record: slo:error_budget_remaining:ratio
        expr: |
          1 - (slo:error_rate:30d / slo:error_budget:ratio)
        labels:
          slo_target: "99.9"
```

### Latency SLI Recording Rules

```yaml
groups:
  - name: slo_latency_recording_rules
    interval: 30s
    rules:
      # ==================================
      # Latency SLI: % of requests < 500ms
      # ==================================

      - record: sli:http_latency_500ms:ratio_5m
        expr: |
          sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m])) by (service)
            /
          sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[5m])) by (service)

      - record: sli:http_latency_500ms:ratio_30m
        expr: |
          sum(rate(http_request_duration_seconds_bucket{le="0.5"}[30m])) by (service)
            /
          sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[30m])) by (service)

      - record: sli:http_latency_500ms:ratio_1h
        expr: |
          sum(rate(http_request_duration_seconds_bucket{le="0.5"}[1h])) by (service)
            /
          sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[1h])) by (service)

      - record: sli:http_latency_500ms:ratio_6h
        expr: |
          sum(rate(http_request_duration_seconds_bucket{le="0.5"}[6h])) by (service)
            /
          sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[6h])) by (service)

      # ==================================
      # Latency Error Rate (slow requests)
      # ==================================

      - record: slo:latency_error_rate:5m
        expr: 1 - sli:http_latency_500ms:ratio_5m

      - record: slo:latency_error_rate:30m
        expr: 1 - sli:http_latency_500ms:ratio_30m

      - record: slo:latency_error_rate:1h
        expr: 1 - sli:http_latency_500ms:ratio_1h

      - record: slo:latency_error_rate:6h
        expr: 1 - sli:http_latency_500ms:ratio_6h

      # ==================================
      # Latency Burn Rate
      # ==================================

      - record: burn_rate:http_latency:5m
        expr: |
          slo:latency_error_rate:5m / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_latency:30m
        expr: |
          slo:latency_error_rate:30m / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_latency:1h
        expr: |
          slo:latency_error_rate:1h / ignoring(slo_target) slo:error_budget:ratio

      - record: burn_rate:http_latency:6h
        expr: |
          slo:latency_error_rate:6h / ignoring(slo_target) slo:error_budget:ratio
```

---

## Performance Recording Rules

### Request Aggregations

Pre-compute common aggregations to accelerate dashboards:

```yaml
groups:
  - name: performance_recording_rules
    interval: 30s
    rules:
      # Total requests per second by service
      - record: service:http_requests:rate_5m
        expr: |
          sum(rate(http_requests_total[5m])) by (service)

      # Total requests per second by method
      - record: service:http_requests_by_method:rate_5m
        expr: |
          sum(rate(http_requests_total[5m])) by (service, method)

      # Total requests per second by status code
      - record: service:http_requests_by_status:rate_5m
        expr: |
          sum(rate(http_requests_total[5m])) by (service, status)

      # Success rate (2xx + 3xx)
      - record: service:http_success_rate:ratio_5m
        expr: |
          sum(rate(http_requests_total{status=~"[23].."}[5m])) by (service)
            /
          sum(rate(http_requests_total[5m])) by (service)

      # Client error rate (4xx)
      - record: service:http_client_error_rate:ratio_5m
        expr: |
          sum(rate(http_requests_total{status=~"4.."}[5m])) by (service)
            /
          sum(rate(http_requests_total[5m])) by (service)

      # Server error rate (5xx)
      - record: service:http_server_error_rate:ratio_5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
            /
          sum(rate(http_requests_total[5m])) by (service)
```

### Latency Aggregations

```yaml
groups:
  - name: latency_recording_rules
    interval: 30s
    rules:
      # P50 latency
      - record: service:http_latency:p50_5m
        expr: |
          histogram_quantile(0.50,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          )

      # P90 latency
      - record: service:http_latency:p90_5m
        expr: |
          histogram_quantile(0.90,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          )

      # P95 latency
      - record: service:http_latency:p95_5m
        expr: |
          histogram_quantile(0.95,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          )

      # P99 latency
      - record: service:http_latency:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          )

      # P99.9 latency
      - record: service:http_latency:p999_5m
        expr: |
          histogram_quantile(0.999,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          )

      # Average latency
      - record: service:http_latency:avg_5m
        expr: |
          rate(http_request_duration_seconds_sum[5m])
            /
          rate(http_request_duration_seconds_count[5m])
```

---

## Aggregation Recording Rules

### Cross-Service Aggregations

Aggregate metrics across multiple services:

```yaml
groups:
  - name: cluster_aggregation_rules
    interval: 30s
    rules:
      # Cluster-wide request rate
      - record: cluster:http_requests:rate_5m
        expr: sum(service:http_requests:rate_5m)

      # Cluster-wide availability
      - record: cluster:http_availability:ratio_5m
        expr: |
          sum(rate(http_requests_total{status!~"5.."}[5m]))
            /
          sum(rate(http_requests_total[5m]))

      # Cluster-wide error rate
      - record: cluster:http_error_rate:ratio_5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m]))
            /
          sum(rate(http_requests_total[5m]))

      # Weighted average latency across services
      - record: cluster:http_latency:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
          )
```

### Per-Endpoint Aggregations

Track performance of individual endpoints:

```yaml
groups:
  - name: endpoint_aggregation_rules
    interval: 30s
    rules:
      # Request rate per endpoint
      - record: endpoint:http_requests:rate_5m
        expr: |
          sum(rate(http_requests_total[5m])) by (service, endpoint)

      # Error rate per endpoint
      - record: endpoint:http_error_rate:ratio_5m
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m])) by (service, endpoint)
            /
          sum(rate(http_requests_total[5m])) by (service, endpoint)

      # P99 latency per endpoint
      - record: endpoint:http_latency:p99_5m
        expr: |
          histogram_quantile(0.99,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service, endpoint)
          )
```

---

## Best Practices

### Rule Group Organization

**Separate groups by evaluation frequency:**

```yaml
# Fast evaluation for critical metrics
groups:
  - name: slo_critical
    interval: 15s
    rules:
      - record: sli:http_availability:ratio_5m
        expr: ...

# Standard evaluation for most metrics
groups:
  - name: slo_standard
    interval: 30s
    rules:
      - record: sli:http_availability:ratio_1h
        expr: ...

# Slow evaluation for long-window metrics
groups:
  - name: slo_long_term
    interval: 1m
    rules:
      - record: sli:http_availability:ratio_30d
        expr: ...
```

### Minimize Cardinality

**Avoid high-cardinality labels in recording rules:**

```yaml
# ❌ Bad: Creates thousands of time series
- record: service:http_requests:rate_5m
  expr: |
    sum(rate(http_requests_total[5m])) by (service, user_id, session_id)

# ✅ Good: Low cardinality
- record: service:http_requests:rate_5m
  expr: |
    sum(rate(http_requests_total[5m])) by (service)
```

### Use Consistent Time Windows

**Align windows with alerting needs:**

```yaml
# For multi-window burn rate alerts, use these windows:
# 5m, 30m, 1h, 2h, 6h, 1d, 3d, 30d

# Don't create arbitrary windows like:
# 7m, 45m, 90m, 5d  ❌
```

### Document Complex Expressions

```yaml
- record: sli:http_availability:ratio_5m
  expr: |
    # Availability SLI: Percentage of HTTP requests with status < 500
    # Used for SLO tracking and burn rate alerts
    # SLO Target: 99.9% over 30 days
    sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
```

### Layer Recording Rules

Build complex metrics from simpler ones:

```yaml
# Layer 1: Basic SLI
- record: sli:http_availability:ratio_5m
  expr: ...

# Layer 2: Error rate (derived from SLI)
- record: slo:error_rate:5m
  expr: 1 - sli:http_availability:ratio_5m

# Layer 3: Burn rate (derived from error rate)
- record: burn_rate:http_availability:5m
  expr: slo:error_rate:5m / slo:error_budget:ratio
```

**Benefits:**
- Easier to understand
- Easier to debug
- Changes propagate automatically

---

## Testing and Validation

### Validate Syntax

Use `promtool` to check rule files:

```bash
promtool check rules /path/to/rules.yml
```

**Output:**
```
Checking /path/to/rules.yml
  SUCCESS: 15 rules found
```

### Compare Results

Verify recording rule matches direct query:

```bash
# Query the recording rule
curl -s 'http://localhost:9090/api/v1/query?query=sli:http_availability:ratio_5m'

# Query the original expression
curl -s 'http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{status!~"5.."}[5m]))%20by%20(service)%20%2F%20sum(rate(http_requests_total[5m]))%20by%20(service)'

# Results should match
```

### Monitor Rule Evaluation Time

Check if rules are slow to evaluate:

```promql
# Rule group duration
prometheus_rule_group_duration_seconds{group="slo_recording_rules"}

# Rule evaluation failures
rate(prometheus_rule_evaluation_failures_total[5m])
```

**If evaluation time > interval:**
- Reduce cardinality in `by` clause
- Split into multiple groups
- Optimize underlying queries

### Track Recording Rule Storage

Monitor storage impact:

```promql
# Total time series created by recording rules
count(up{job="prometheus"}) by (job)

# Time series per recording rule (requires metric name)
count({__name__=~"sli:.*|slo:.*|burn_rate:.*"}) by (__name__)
```

---

## Loki Recording Rules

Loki supports recording rules for deriving metrics from logs:

```yaml
groups:
  - name: log_derived_metrics
    interval: 1m
    rules:
      # Count error logs
      - record: log:errors:rate_5m
        expr: |
          sum(rate({app="api"} |= "ERROR" [5m])) by (namespace)

      # Count specific error patterns
      - record: log:database_errors:rate_5m
        expr: |
          sum(rate({app="api"} |~ "database.*connection.*failed" [5m])) by (namespace)

      # Extract numeric values from logs (e.g., processing time)
      - record: log:processing_time:avg_5m
        expr: |
          avg_over_time({app="worker"} | json | unwrap processing_time_ms [5m])
```

**Use case:** Generate Prometheus metrics from log data for alerting or dashboards.

---

## References

- [Prometheus: Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
- [Grafana Mimir: Ruler](https://grafana.com/docs/mimir/latest/references/architecture/components/ruler/)
- [Grafana Loki: Recording Rules](https://grafana.com/docs/loki/latest/alert/)
- [Google SRE: Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)
