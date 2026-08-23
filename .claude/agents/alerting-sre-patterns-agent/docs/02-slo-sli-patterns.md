# SLO/SLI Patterns: Service Level Objectives and Indicators

**Created:** 2025-11-28
**Purpose:** Comprehensive guide to defining, measuring, and alerting on Service Level Objectives

---

## Table of Contents

1. [SLO/SLI Fundamentals](#slosli-fundamentals)
2. [Common SLI Types](#common-sli-types)
3. [SLO Target Setting](#slo-target-setting)
4. [Error Budget Calculation](#error-budget-calculation)
5. [SLI Implementation Patterns](#sli-implementation-patterns)
6. [Recording Rules for SLIs](#recording-rules-for-slis)
7. [SLO-Based Alerting Strategy](#slo-based-alerting-strategy)

---

## SLO/SLI Fundamentals

### Definitions

**SLI (Service Level Indicator)**: A carefully defined quantitative measure of some aspect of the level of service that is provided.

**SLO (Service Level Objective)**: A target value or range of values for a service level that is measured by an SLI.

**Error Budget**: The maximum amount of time that a technical system can fail without contractual consequences. Calculated as `1 - SLO`.

### Example

**SLI**: Percentage of HTTP requests that complete successfully (status < 500)
**SLO**: 99.9% of requests succeed over a 30-day period
**Error Budget**: 0.1% of requests can fail (43.2 minutes of downtime per month)

### Why SLOs Matter

1. **User-centric**: Focus on what users actually experience
2. **Risk-based**: Alert only when user experience is at risk
3. **Data-driven**: Make deployment and incident decisions based on error budget consumption
4. **Reduce alert fatigue**: Stop alerting on symptoms when SLOs are met

### The Golden Signals

Google SRE recommends monitoring these four key metrics:

1. **Latency**: How long it takes to serve a request
2. **Traffic**: How much demand is being placed on your system
3. **Errors**: The rate of requests that fail
4. **Saturation**: How "full" your service is

**SLIs should be based on these signals**, prioritizing latency and errors for user-facing services.

---

## Common SLI Types

### Availability SLI

**Definition**: Proportion of valid requests served successfully

**Measurement**: Ratio of successful requests to total requests

```promql
# Good events (successful requests)
sum(rate(http_requests_total{status!~"5.."}[5m]))

# Total events (all requests)
sum(rate(http_requests_total[5m]))

# SLI value
sum(rate(http_requests_total{status!~"5.."}[5m]))
  /
sum(rate(http_requests_total[5m]))
```

**Common thresholds:**
- **Critical services**: 99.99% (52.6 minutes/year downtime)
- **Important services**: 99.9% (8.76 hours/year downtime)
- **Standard services**: 99.5% (1.83 days/year downtime)
- **Internal tools**: 99% (3.65 days/year downtime)

### Latency SLI

**Definition**: Proportion of valid requests served faster than a threshold

**Measurement**: Ratio of fast requests to total requests

```promql
# Good events (fast requests) - using histogram
sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m]))

# Total events
sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[5m]))

# SLI value
sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m]))
  /
sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[5m]))
```

**Alternative: Percentile-based**

```promql
# P99 latency < 500ms
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
) < 0.5
```

**Common thresholds:**
- **Interactive requests**: 99% < 200ms, 99.9% < 1000ms
- **API requests**: 99% < 500ms, 99.9% < 2000ms
- **Batch operations**: 99% < 5s, 99.9% < 30s
- **Report generation**: 99% < 30s, 99.9% < 60s

### Data Freshness SLI

**Definition**: Proportion of time data is no older than a threshold

**Measurement**: Time since last successful update

```promql
# Good events (fresh data)
(time() - last_successful_update_timestamp_seconds) < 300

# For ratio-based approach
sum(rate(data_update_success_total[5m]))
  /
sum(rate(data_update_attempts_total[5m]))
```

**Common thresholds:**
- **Real-time dashboards**: 99.9% < 60s stale
- **Analytics dashboards**: 99% < 15min stale
- **Batch reports**: 95% < 24h stale

### Durability SLI

**Definition**: Proportion of records written that can be successfully read

**Measurement**: Read success rate for previously written data

```promql
# Good events (successful reads of known data)
sum(rate(read_success_total[5m]))

# Total events (all read attempts)
sum(rate(read_attempts_total[5m]))

# SLI value
sum(rate(read_success_total[5m]))
  /
sum(rate(read_attempts_total[5m]))
```

**Common thresholds:**
- **Critical data**: 99.999% (eleven nines)
- **User data**: 99.99%
- **Cached data**: 99.9%

### Throughput SLI

**Definition**: Proportion of time system can handle target load

**Measurement**: Current throughput vs capacity

```promql
# Good events (within capacity)
(
  sum(rate(requests_total[5m]))
    /
  scalar(max(system_capacity_requests_per_second))
) < 0.8  # 80% capacity threshold
```

**Common thresholds:**
- **Sustained load**: 99% below 80% capacity
- **Peak load**: 95% below 90% capacity

---

## SLO Target Setting

### The 9s Framework

| SLO | Downtime/Month | Downtime/Year | Use Case |
|-----|----------------|---------------|----------|
| 90% | 72 hours | 36.5 days | Internal experiments |
| 95% | 36 hours | 18.25 days | Internal tools |
| 99% | 7.2 hours | 3.65 days | Standard services |
| 99.5% | 3.6 hours | 1.83 days | Important services |
| 99.9% | 43.2 minutes | 8.76 hours | Critical user-facing |
| 99.95% | 21.6 minutes | 4.38 hours | Payment systems |
| 99.99% | 4.32 minutes | 52.6 minutes | Core platform |
| 99.999% | 26 seconds | 5.26 minutes | Financial transactions |

### Factors for Setting SLOs

1. **User expectations**: What do users need for a good experience?
2. **Competitive landscape**: What do similar services offer?
3. **Business requirements**: What does the business commit to customers?
4. **Current performance**: What are you achieving today?
5. **Cost of improvement**: What's the engineering cost to improve?
6. **Dependencies**: What's the reliability of your dependencies?

### Starting Point Recommendations

**For new services:**
- Start at **99%** (achievable baseline)
- Measure actual performance for 1-2 months
- Increase target if consistently exceeding it
- Decrease target if causing excessive toil

**The Rule of Thumb**: Your SLO should be slightly below your actual performance to provide a buffer for unexpected issues.

### Multiple SLOs for Different Request Types

Bucket requests by criticality rather than per-service granularity:

```yaml
# CRITICAL bucket (login, authentication)
slo_target: 99.99%
latency_threshold: 200ms

# HIGH_FAST bucket (interactive features)
slo_target: 99.9%
latency_threshold: 500ms

# HIGH_SLOW bucket (reports, exports)
slo_target: 99.9%
latency_threshold: 5000ms

# LOW bucket (background processing)
slo_target: 99%
latency_threshold: 30000ms

# NO_SLO bucket (experimental features)
slo_target: none
```

**Benefits:**
- Reduces operational complexity
- Standardizes alerting across organization
- Provides clear service tiers

---

## Error Budget Calculation

### Basic Formula

```
Error Budget = 1 - SLO Target
Error Budget Minutes = Error Budget × Time Period × 60
```

**Example: 99.9% SLO over 30 days**

```
Error Budget = 1 - 0.999 = 0.001 (0.1%)
Error Budget Minutes = 0.001 × 30 × 24 × 60 = 43.2 minutes
```

### Error Budget Consumption Rate

**Burn Rate**: How quickly you're consuming error budget relative to the SLO period

```
Burn Rate = (Error Rate) / (Error Budget)
```

**Example:**

```
SLO: 99.9% (0.1% error budget)
Current Error Rate: 1%
Burn Rate = 0.01 / 0.001 = 10x

At 10x burn rate, the entire monthly budget will be consumed in 3 days.
```

### Error Budget Policy

Define policies for different budget consumption levels:

**100% budget remaining:**
- Focus on feature development
- Experiment with new technologies
- Deploy whenever ready

**75-100% budget remaining:**
- Normal operations
- Standard deployment cadence
- Continue feature work

**50-75% budget remaining:**
- Increased caution
- Review changes more carefully
- Consider slowing deployment velocity

**25-50% budget remaining:**
- Deployment freeze for risky changes
- Focus on stability improvements
- Prioritize bug fixes over features

**0-25% budget remaining:**
- Production freeze (emergency fixes only)
- All hands on deck for stability
- Root cause analysis required

**Budget exhausted:**
- Complete deployment freeze
- Incident postmortem required
- Executive review before resuming deployments

---

## SLI Implementation Patterns

### Counter-Based Availability SLI

**Instrumentation:**

```python
# Application code
from prometheus_client import Counter

requests_total = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['service', 'method', 'status']
)

# In request handler
requests_total.labels(
    service='api',
    method=request.method,
    status=response.status_code
).inc()
```

**Recording Rule:**

```yaml
- record: sli:http_availability:ratio_5m
  expr: |
    sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
```

### Histogram-Based Latency SLI

**Instrumentation:**

```python
from prometheus_client import Histogram

request_duration = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency',
    ['service', 'method'],
    buckets=[0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
)

# In request handler
with request_duration.labels(
    service='api',
    method=request.method
).time():
    response = handle_request(request)
```

**Recording Rule:**

```yaml
- record: sli:http_latency:ratio_5m
  expr: |
    sum(rate(http_request_duration_seconds_bucket{le="0.5"}[5m])) by (service)
      /
    sum(rate(http_request_duration_seconds_bucket{le="+Inf"}[5m])) by (service)
```

### Log-Based SLI (Loki)

**LogQL Recording Rule:**

```yaml
- record: sli:api_availability:ratio_5m
  expr: |
    (
      sum(rate({app="api", env="production"} != "status=5" [5m]))
        /
      sum(rate({app="api", env="production"}[5m]))
    )
```

**Alternative with structured logs:**

```yaml
- record: sli:api_availability:ratio_5m
  expr: |
    (
      sum(rate({app="api"} | json | status < 500 [5m]))
        /
      sum(rate({app="api"} | json [5m]))
    )
```

---

## Recording Rules for SLIs

### Why Recording Rules?

1. **Performance**: Pre-compute expensive calculations
2. **Consistency**: Same definition used everywhere
3. **Simplification**: Complex queries become simple metric lookups
4. **Alerting**: Enable multi-window burn rate alerts

### Naming Convention

Follow the pattern: `level:metric:operations`

```
sli:http_availability:ratio_5m
sli:http_latency_p99:seconds_5m
slo:error_budget_remaining:ratio
burn_rate:http_availability:1h
```

### Complete SLI Recording Rule Set

```yaml
groups:
  - name: sli_recording_rules
    interval: 30s
    rules:
      # Availability SLI - multiple time windows
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

      # Latency SLI - multiple time windows
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

      # Error budget tracking
      - record: slo:error_budget_remaining:ratio
        expr: |
          1 - (
            (1 - sli:http_availability:ratio_30d) / (1 - 0.999)
          )
        labels:
          slo_target: "99.9"
```

---

## SLO-Based Alerting Strategy

### Principle: Alert on Error Budget Risk, Not Symptoms

**Traditional approach (symptom-based):**
```yaml
# ❌ Alert when error rate crosses fixed threshold
- alert: HighErrorRate
  expr: error_rate > 0.05
```

**SLO-based approach (budget risk):**
```yaml
# ✅ Alert when burning error budget too quickly
- alert: ErrorBudgetBurnHigh
  expr: |
    (burn_rate:http_availability:1h > 14.4)
    and
    (burn_rate:http_availability:5m > 14.4)
```

### Why SLO-Based Alerting is Better

1. **User-centric**: Only alerts when users are actually affected
2. **Reduces noise**: No alerts when SLO is met
3. **Clear severity**: Burn rate indicates urgency
4. **Actionable**: Ties directly to deployment and release decisions

### Multi-Burn-Rate, Multi-Window Pattern

See `03-multi-burn-rate-alerting.md` for complete implementation details.

**Preview:**

```yaml
- alert: ErrorBudgetBurn_Critical
  expr: |
    (burn_rate:http_availability:1h > 14.4)
    and
    (burn_rate:http_availability:5m > 14.4)
  for: 2m
  labels:
    severity: critical
    alert_type: error_budget_burn
  annotations:
    summary: "Critical error budget burn for {{ $labels.service }}"
    description: "Consuming 2% of monthly budget per hour"
```

---

## Low-Traffic Service Challenges

### The Problem

For services with low request rates, a single failed request can create extreme burn rates:

**Example:**
- Service receives 10 requests/hour
- 1 failure = 10% error rate
- With 99.9% SLO (0.1% error budget), burn rate = 10% / 0.1% = 100x
- Alert fires immediately even though user impact is minimal

### Solutions

**1. Synthetic Traffic**

Generate synthetic requests to increase sample size:

```python
# Health check synthetic requests
@app.route('/synthetic-health')
def synthetic_health():
    # Performs actual system checks
    result = check_database() and check_cache()
    return {'status': 'ok' if result else 'error'}, 200 if result else 500
```

**2. Combine Related Services**

Aggregate multiple low-traffic endpoints:

```yaml
- record: sli:user_workflows:availability_5m
  expr: |
    sum(rate(http_requests_total{service=~"login|profile|settings", status!~"5.."}[5m]))
      /
    sum(rate(http_requests_total{service=~"login|profile|settings"}[5m]))
```

**3. Request-Count Threshold**

Require minimum request volume before alerting:

```yaml
- alert: HighErrorRate
  expr: |
    (error_rate > threshold)
    and
    (sum(rate(requests_total[1h])) > 100)  # Minimum 100 requests/hour
```

**4. Lower SLO Targets**

Accept lower reliability for non-critical low-traffic services:

```yaml
# Instead of 99.9%, use 99% for internal tools
slo_target: 0.99
```

**5. Event-Based Alerting**

For very low traffic, switch to event-based alerts:

```yaml
- alert: CriticalEndpointFailure
  expr: |
    increase(http_requests_total{endpoint="/critical-action", status="500"}[5m]) > 0
  labels:
    severity: warning
```

---

## Best Practices

### Start Simple

1. **Begin with one SLO**: Pick availability or latency for your most critical user journey
2. **Use 99% target**: Easy to achieve, provides learning opportunity
3. **Measure for 30 days**: Understand baseline performance before tightening
4. **Add complexity gradually**: Multi-window alerting, error budget policies, etc.

### Choose the Right SLI

**Good SLIs:**
- Directly measure user experience
- Based on actual user requests
- Clear definition of "good" vs "bad"
- Measurable from existing metrics

**Bad SLIs:**
- Internal implementation details (CPU, memory)
- Proxy metrics not tied to user experience
- Impossible to measure accurately
- Too many edge cases in definition

### Document Everything

```yaml
# ✅ Good: Well-documented SLO
- record: sli:api_availability:ratio_5m
  expr: |
    # SLI: Percentage of HTTP requests that return status < 500
    # SLO: 99.9% of requests succeed over 30 days
    # Error Budget: 43.2 minutes of 5xx errors per month
    # Owner: Platform Team (@platform-oncall)
    # Dashboard: https://grafana.example.com/d/api-slo
    sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
      /
    sum(rate(http_requests_total[5m])) by (service)
```

### Review and Iterate

- **Weekly**: Check error budget consumption trends
- **Monthly**: Review alert quality (false positives, missed incidents)
- **Quarterly**: Reassess SLO targets based on user feedback and business needs
- **Annually**: Major SLO review with stakeholders

---

## References

- [Google SRE Book: Service Level Objectives](https://sre.google/sre-book/service-level-objectives/)
- [Google SRE Workbook: Implementing SLOs](https://sre.google/workbook/implementing-slos/)
- [Google SRE Workbook: Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [Prometheus: Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
