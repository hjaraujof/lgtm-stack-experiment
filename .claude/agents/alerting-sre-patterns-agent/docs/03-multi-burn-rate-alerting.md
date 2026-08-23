# Multi-Window Multi-Burn-Rate Alerting

**Created:** 2025-11-28
**Purpose:** Comprehensive implementation guide for Google SRE's multi-window multi-burn-rate alerting methodology

---

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Why Multiple Windows?](#why-multiple-windows)
3. [Burn Rate Calculation](#burn-rate-calculation)
4. [Recommended Alert Tiers](#recommended-alert-tiers)
5. [Complete Implementation Example](#complete-implementation-example)
6. [PromQL Implementation](#promql-implementation)
7. [LogQL Implementation](#logql-implementation)
8. [Recording Rules Setup](#recording-rules-setup)
9. [Alert Configuration](#alert-configuration)
10. [Operational Patterns](#operational-patterns)

---

## Core Concepts

### The Evolution

Google SRE iterated through six alerting approaches before arriving at multi-window multi-burn-rate alerts:

1. **Target error rate**: Alert when error rate > (1 - SLO) ❌ Too noisy
2. **Increased window**: Longer time windows ❌ Slow detection
3. **Incrementing**: 10% budget in 1 day or 5% in 6 hours ❌ Complex
4. **Multiple burn rates**: Different rates for page vs ticket ❌ Slow reset time
5. **Multi-window single burn rate**: Same burn rate, two windows ❌ Too sensitive
6. **Multi-window multi-burn-rate**: ✅ Optimal balance

### Key Innovation

**Require BOTH a long window AND a short window to exceed the burn rate threshold.**

**Logic:**
```
Alert = (long_window_burn_rate > threshold) AND (short_window_burn_rate > threshold)
```

**Benefits:**
- **Long window**: Prevents transient spikes from triggering alerts
- **Short window**: Enables fast reset once issue is resolved
- **Combined**: Low false positive rate with quick recovery

### The Four Evaluation Criteria

1. **Precision**: Proportion of alerts that represent real problems
2. **Recall**: Proportion of real problems that trigger alerts
3. **Detection Time**: How quickly alerts fire after issue starts
4. **Reset Time**: How quickly alerts resolve after issue ends

Multi-window multi-burn-rate alerts score high on all four metrics.

---

## Why Multiple Windows?

### Problem with Single-Window Alerts

**Long window only:**
```yaml
# ❌ Slow to reset after issue resolves
expr: (error_rate[1h] / error_budget) > 14.4
```

After fixing an issue, the alert remains firing until errors clear from the 1-hour window (potentially 30+ minutes).

**Short window only:**
```yaml
# ❌ Too sensitive to transient spikes
expr: (error_rate[5m] / error_budget) > 14.4
```

Brief error spikes trigger unnecessary pages even if they don't threaten the SLO.

### Solution: Dual-Window Logic

```yaml
# ✅ Best of both worlds
expr: |
  (error_rate[1h] / error_budget > 14.4)
  and
  (error_rate[5m] / error_budget > 14.4)
```

**How it works:**

1. **Issue starts**: Error rate increases
2. **After ~5 minutes**: Short window (5m) exceeds threshold
3. **After ~30 minutes**: Long window (1h) exceeds threshold → **Alert fires**
4. **Issue resolved**: Error rate drops
5. **After ~5 minutes**: Short window drops below threshold → **Alert resolves**

**Result:**
- Ignores brief spikes (need sustained error to trigger)
- Resets quickly (within 5-10 minutes of resolution)

---

## Burn Rate Calculation

### Definition

**Burn Rate**: How fast you're consuming error budget relative to the SLO period.

```
Burn Rate = (Actual Error Rate) / (Error Budget)
```

**Interpretation:**
- Burn rate of **1** = Consuming budget exactly at SLO rate (will hit 0% budget at period end)
- Burn rate of **10** = Consuming budget 10x faster (will exhaust in 1/10th the time)
- Burn rate of **0.5** = Consuming budget slowly (will have budget remaining)

### Example: 99.9% SLO over 30 days

```
Error Budget = 1 - 0.999 = 0.001 (0.1%)
```

**Scenario 1: 1% error rate**
```
Burn Rate = 0.01 / 0.001 = 10
Budget exhaustion = 30 days / 10 = 3 days
```

**Scenario 2: 5% error rate**
```
Burn Rate = 0.05 / 0.001 = 50
Budget exhaustion = 30 days / 50 = 14.4 hours
```

**Scenario 3: 0.05% error rate**
```
Burn Rate = 0.0005 / 0.001 = 0.5
Budget exhaustion = Never (under budget)
```

### Burn Rate as Urgency Signal

High burn rate = Urgent problem requiring immediate attention
Low burn rate = Degraded but not critical, can wait for business hours

---

## Recommended Alert Tiers

### Standard Configuration (99.9% SLO)

Google SRE recommends these starting parameters:

| Severity | Long Window | Short Window | Burn Rate | Budget Consumed | For Duration |
|----------|-------------|--------------|-----------|-----------------|--------------|
| **Page** | 1 hour | 5 minutes | 14.4x | 2% in 1 hour | 2 minutes |
| **Page** | 6 hours | 30 minutes | 6x | 5% in 6 hours | 15 minutes |
| **Ticket** | 1 day | 2 hours | 3x | 10% in 1 day | 1 hour |
| **Ticket** | 3 days | 6 hours | 1x | 10% in 3 days | 3 hours |

**Four-tier rationale:**

1. **High-burn page** (14.4x): Catches acute incidents requiring immediate response
2. **Medium-burn page** (6x): Catches degradation that will exhaust budget in ~5 days
3. **Low-burn ticket** (3x): Catches slow degradation, creates ticket for business hours
4. **Monitoring ticket** (1x): Budget consumption exactly at SLO rate, may indicate systemic issue

### Adjustments for Different SLOs

**99.5% SLO:**

| Severity | Long Window | Short Window | Burn Rate | Budget Impact |
|----------|-------------|--------------|-----------|---------------|
| Page | 1 hour | 5 minutes | 7.2x | 2% |
| Page | 6 hours | 30 minutes | 3x | 5% |
| Ticket | 1 day | 2 hours | 1.5x | 10% |

**99.95% SLO:**

| Severity | Long Window | Short Window | Burn Rate | Budget Impact |
|----------|-------------|--------------|-----------|---------------|
| Page | 1 hour | 5 minutes | 28.8x | 2% |
| Page | 6 hours | 30 minutes | 12x | 5% |
| Ticket | 1 day | 2 hours | 6x | 10% |

**99.99% SLO:**

| Severity | Long Window | Short Window | Burn Rate | Budget Impact |
|----------|-------------|--------------|-----------|---------------|
| Page | 1 hour | 5 minutes | 144x | 2% |
| Page | 6 hours | 30 minutes | 60x | 5% |
| Ticket | 1 day | 2 hours | 30x | 10% |

### Window Ratio Rule

**Short window should be 1/12th of long window:**

```
1 hour / 5 minutes = 12
6 hours / 30 minutes = 12
1 day / 2 hours = 12
3 days / 6 hours = 12
```

This ratio provides optimal balance between detection and reset time.

---

## Complete Implementation Example

### Scenario: API Service with 99.9% Availability SLO

**Metrics available:**
```promql
http_requests_total{service="api", status}
```

### Step 1: Define Base SLI

```promql
# Availability SLI: ratio of successful requests to total requests
sum(rate(http_requests_total{service="api", status!~"5.."}[5m]))
  /
sum(rate(http_requests_total{service="api"}[5m]))
```

### Step 2: Calculate Error Budget and Burn Rates

```
SLO Target: 99.9%
Error Budget: 0.1%
Period: 30 days

High-burn threshold: 14.4x burn rate
- Means: 14.4 × 0.001 = 0.0144 (1.44% error rate)
- Exhausts: 2% of budget per hour

Medium-burn threshold: 6x burn rate
- Means: 6 × 0.001 = 0.006 (0.6% error rate)
- Exhausts: 5% of budget in 6 hours
```

### Step 3: Create Recording Rules

See "Recording Rules Setup" section below for complete YAML.

### Step 4: Create Alert Rules

See "Alert Configuration" section below for complete YAML.

---

## PromQL Implementation

### Availability-Based Alerts

**High-burn page alert (14.4x, 1h/5m):**

```promql
(
  # Long window: 1 hour
  (
    1 - (
      sum(rate(http_requests_total{service="api", status!~"5.."}[1h]))
        /
      sum(rate(http_requests_total{service="api"}[1h]))
    )
  ) > (14.4 * 0.001)
)
and
(
  # Short window: 5 minutes
  (
    1 - (
      sum(rate(http_requests_total{service="api", status!~"5.."}[5m]))
        /
      sum(rate(http_requests_total{service="api"}[5m]))
    )
  ) > (14.4 * 0.001)
)
```

**Medium-burn page alert (6x, 6h/30m):**

```promql
(
  (1 - (
    sum(rate(http_requests_total{service="api", status!~"5.."}[6h]))
      /
    sum(rate(http_requests_total{service="api"}[6h]))
  )) > (6 * 0.001)
)
and
(
  (1 - (
    sum(rate(http_requests_total{service="api", status!~"5.."}[30m]))
      /
    sum(rate(http_requests_total{service="api"}[30m]))
  )) > (6 * 0.001)
)
```

### Latency-Based Alerts

**High-burn page alert for latency SLO (99.9% < 500ms):**

```promql
(
  # Long window: error rate = requests slower than 500ms
  (
    1 - (
      sum(rate(http_request_duration_seconds_bucket{service="api", le="0.5"}[1h]))
        /
      sum(rate(http_request_duration_seconds_bucket{service="api", le="+Inf"}[1h]))
    )
  ) > (14.4 * 0.001)
)
and
(
  # Short window
  (
    1 - (
      sum(rate(http_request_duration_seconds_bucket{service="api", le="0.5"}[5m]))
        /
      sum(rate(http_request_duration_seconds_bucket{service="api", le="+Inf"}[5m]))
    )
  ) > (14.4 * 0.001)
)
```

### Using Recording Rules (Simplified)

**With recording rules pre-computed:**

```promql
# High-burn page alert
(burn_rate:http_availability:1h > 14.4)
and
(burn_rate:http_availability:5m > 14.4)

# Medium-burn page alert
(burn_rate:http_availability:6h > 6)
and
(burn_rate:http_availability:30m > 6)

# Low-burn ticket alert
(burn_rate:http_availability:1d > 3)
and
(burn_rate:http_availability:2h > 3)
```

**Much simpler and more performant!**

---

## LogQL Implementation

### Availability from Logs

**Assuming logs contain HTTP status codes:**

```yaml
# High-burn page alert (14.4x, 1h/5m)
expr: |
  (
    (
      1 - (
        sum(rate({app="api", env="production"} != "status=5" [1h]))
          /
        sum(rate({app="api", env="production"}[1h]))
      )
    ) > (14.4 * 0.001)
  )
  and
  (
    (
      1 - (
        sum(rate({app="api", env="production"} != "status=5" [5m]))
          /
        sum(rate({app="api", env="production"}[5m]))
      )
    ) > (14.4 * 0.001)
  )
```

### With Structured Logs (JSON)

```yaml
# Using JSON parsing
expr: |
  (
    (
      1 - (
        sum(rate({app="api"} | json | status < 500 [1h]))
          /
        sum(rate({app="api"} | json [1h]))
      )
    ) > (14.4 * 0.001)
  )
  and
  (
    (
      1 - (
        sum(rate({app="api"} | json | status < 500 [5m]))
          /
        sum(rate({app="api"} | json [5m]))
      )
    ) > (14.4 * 0.001)
  )
```

### Error Rate from Error Logs

**If only errors are logged:**

```yaml
# Burn rate based on error log volume vs expected baseline
expr: |
  (
    (
      sum(rate({app="api", level="error"}[1h]))
        /
      scalar(baseline_requests_per_second)
    ) > (14.4 * 0.001)
  )
  and
  (
    (
      sum(rate({app="api", level="error"}[5m]))
        /
      scalar(baseline_requests_per_second)
    ) > (14.4 * 0.001)
  )
```

---

## Recording Rules Setup

### Complete Recording Rule Configuration

```yaml
groups:
  - name: slo_burn_rate_recording_rules
    interval: 30s
    rules:
      # =========================================
      # Error Rate Recording Rules (for burn rate calculation)
      # =========================================

      # 5-minute window
      - record: slo:error_rate:5m
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
              /
            sum(rate(http_requests_total[5m])) by (service)
          )

      # 30-minute window
      - record: slo:error_rate:30m
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[30m])) by (service)
              /
            sum(rate(http_requests_total[30m])) by (service)
          )

      # 1-hour window
      - record: slo:error_rate:1h
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[1h])) by (service)
              /
            sum(rate(http_requests_total[1h])) by (service)
          )

      # 2-hour window
      - record: slo:error_rate:2h
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[2h])) by (service)
              /
            sum(rate(http_requests_total[2h])) by (service)
          )

      # 6-hour window
      - record: slo:error_rate:6h
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[6h])) by (service)
              /
            sum(rate(http_requests_total[6h])) by (service)
          )

      # 1-day window
      - record: slo:error_rate:1d
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[1d])) by (service)
              /
            sum(rate(http_requests_total[1d])) by (service)
          )

      # 3-day window
      - record: slo:error_rate:3d
        expr: |
          1 - (
            sum(rate(http_requests_total{status!~"5.."}[3d])) by (service)
              /
            sum(rate(http_requests_total[3d])) by (service)
          )

      # =========================================
      # Burn Rate Recording Rules
      # =========================================

      # Define error budget as a metric (for 99.9% SLO)
      - record: slo:error_budget:ratio
        expr: 0.001
        labels:
          slo_target: "99.9"

      # Calculate burn rates for each window
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

      # =========================================
      # Error Budget Remaining
      # =========================================

      - record: slo:error_budget_remaining:ratio_30d
        expr: |
          1 - (
            (slo:error_rate:30d / slo:error_budget:ratio)
          )
        labels:
          slo_target: "99.9"
```

---

## Alert Configuration

### Complete Alert Rule Configuration

```yaml
groups:
  - name: slo_burn_rate_alerts
    interval: 30s
    rules:
      # =========================================
      # CRITICAL: High-burn page (14.4x, 1h/5m)
      # Consuming 2% of monthly budget per hour
      # =========================================
      - alert: ErrorBudgetBurn_Critical
        expr: |
          (burn_rate:http_availability:1h{service="api"} > 14.4)
          and
          (burn_rate:http_availability:5m{service="api"} > 14.4)
        for: 2m
        labels:
          severity: critical
          alert_type: error_budget_burn
          priority: p1
          team: platform
        annotations:
          summary: "CRITICAL: Rapid error budget burn for {{ $labels.service }}"
          description: |
            Service {{ $labels.service }} is burning error budget at 14.4x rate.

            Current burn rate: {{ $value }}x
            Budget impact: 2% of monthly budget consumed per hour
            Time to exhaustion: ~2 days at current rate

            This requires immediate attention.
          runbook_url: "https://wiki.example.com/runbooks/error-budget-burn-critical"
          dashboard_url: "https://grafana.example.com/d/slo-dashboard?var-service={{ $labels.service }}"

      # =========================================
      # WARNING: Medium-burn page (6x, 6h/30m)
      # Consuming 5% of monthly budget in 6 hours
      # =========================================
      - alert: ErrorBudgetBurn_High
        expr: |
          (burn_rate:http_availability:6h{service="api"} > 6)
          and
          (burn_rate:http_availability:30m{service="api"} > 6)
        for: 15m
        labels:
          severity: warning
          alert_type: error_budget_burn
          priority: p2
          team: platform
        annotations:
          summary: "HIGH: Elevated error budget burn for {{ $labels.service }}"
          description: |
            Service {{ $labels.service }} is burning error budget at 6x rate.

            Current burn rate: {{ $value }}x
            Budget impact: 5% of monthly budget in 6 hours
            Time to exhaustion: ~5 days at current rate

            Investigation recommended within business hours.
          runbook_url: "https://wiki.example.com/runbooks/error-budget-burn-high"
          dashboard_url: "https://grafana.example.com/d/slo-dashboard?var-service={{ $labels.service }}"

      # =========================================
      # INFO: Low-burn ticket (3x, 1d/2h)
      # Consuming 10% of monthly budget per day
      # =========================================
      - alert: ErrorBudgetBurn_Medium
        expr: |
          (burn_rate:http_availability:1d{service="api"} > 3)
          and
          (burn_rate:http_availability:2h{service="api"} > 3)
        for: 1h
        labels:
          severity: info
          alert_type: error_budget_burn
          priority: p3
          team: platform
        annotations:
          summary: "MEDIUM: Sustained error budget burn for {{ $labels.service }}"
          description: |
            Service {{ $labels.service }} is burning error budget at 3x rate.

            Current burn rate: {{ $value }}x
            Budget impact: 10% of monthly budget per day
            Time to exhaustion: ~10 days at current rate

            Create ticket for investigation.
          runbook_url: "https://wiki.example.com/runbooks/error-budget-burn-medium"
          dashboard_url: "https://grafana.example.com/d/slo-dashboard?var-service={{ $labels.service }}"

      # =========================================
      # INFO: Baseline ticket (1x, 3d/6h)
      # Consuming budget exactly at SLO rate
      # =========================================
      - alert: ErrorBudgetBurn_Low
        expr: |
          (burn_rate:http_availability:3d{service="api"} > 1)
          and
          (burn_rate:http_availability:6h{service="api"} > 1)
        for: 3h
        labels:
          severity: info
          alert_type: error_budget_burn
          priority: p4
          team: platform
        annotations:
          summary: "LOW: Error budget consumption at SLO rate for {{ $labels.service }}"
          description: |
            Service {{ $labels.service }} is burning error budget at 1x rate.

            Current burn rate: {{ $value }}x
            Budget impact: Will exhaust budget by end of month

            Monitor for trends. May indicate systemic issue.
          runbook_url: "https://wiki.example.com/runbooks/error-budget-burn-low"
          dashboard_url: "https://grafana.example.com/d/slo-dashboard?var-service={{ $labels.service }}"
```

---

## Operational Patterns

### Tuning the `for` Duration

Google SRE recommends minimal or no `for` duration in theory, but practical implementations often include brief durations to filter noise.

**SoundCloud's approach:**

| Alert Tier | For Duration | Rationale |
|-----------|-------------|-----------|
| Critical (14.4x) | 2 minutes | Filter startup anomalies |
| High (6x) | 15 minutes | Confirm sustained degradation |
| Medium (3x) | 1 hour | Avoid ticket spam |
| Low (1x) | 3 hours | Only care about persistent issues |

**Trade-off:**
- **Longer `for`**: Fewer false positives, but slower detection
- **Shorter `for`**: Faster detection, but more noise

### Handling Alert Storms

When multiple services share dependencies, one failure can trigger cascading alerts.

**Inhibition rule to suppress downstream alerts:**

```yaml
# In Alertmanager configuration
inhibit_rules:
  - source_match:
      severity: 'critical'
      component: 'database'
    target_match_re:
      component: 'api|frontend|backend'
    equal: ['environment']
```

**Logic:** If database has critical alert, suppress alerts from services that depend on it.

### Progressive Escalation

Route alerts to different teams based on burn rate:

```yaml
# Alertmanager routing
routes:
  - match:
      alert_type: error_budget_burn
      severity: critical
    receiver: pagerduty-oncall
    group_wait: 10s
    group_interval: 5m
    repeat_interval: 4h

  - match:
      alert_type: error_budget_burn
      severity: warning
    receiver: slack-platform-team
    group_wait: 30s
    group_interval: 10m
    repeat_interval: 12h

  - match:
      alert_type: error_budget_burn
      severity: info
    receiver: jira-ticket-creation
    group_wait: 5m
    group_interval: 1h
    repeat_interval: 24h
```

### Budget Depletion Tracking

Create meta-alert for overall budget status:

```yaml
- alert: ErrorBudgetDepleted
  expr: |
    slo:error_budget_remaining:ratio_30d < 0
  for: 1h
  labels:
    severity: critical
    team: platform
  annotations:
    summary: "ERROR BUDGET EXHAUSTED for {{ $labels.service }}"
    description: |
      Service {{ $labels.service }} has exhausted its error budget for this period.

      Remaining budget: {{ $value | humanizePercentage }}

      IMMEDIATE ACTION REQUIRED:
      - Implement deployment freeze
      - Focus all efforts on stability
      - Executive review before resuming feature work
```

### Testing Alerts

**Inject synthetic errors to verify alerting:**

```bash
# Generate 5% error rate for 10 minutes
for i in {1..600}; do
  # 5 successful requests
  for j in {1..5}; do
    curl -s http://api.example.com/health > /dev/null
  done

  # 1 error request (95% success = 5% error)
  curl -s http://api.example.com/force-error > /dev/null

  sleep 1
done
```

**Expected behavior:**
- After ~5 minutes: Short window (5m) burn rate exceeds 14.4x
- After ~30 minutes: Long window (1h) burn rate exceeds 14.4x → Alert fires
- After stopping errors: Alert resolves within 5-10 minutes

---

## Best Practices

1. **Start with two tiers**: Critical (14.4x) and High (6x) before adding Medium and Low
2. **Use recording rules**: Pre-compute burn rates for performance and consistency
3. **Document thresholds**: Include error budget impact in annotations
4. **Test thoroughly**: Verify alerts fire and resolve as expected
5. **Review weekly**: Check for false positives and adjust thresholds
6. **Combine with runbooks**: Every alert should have actionable remediation steps
7. **Monitor alert quality**: Track precision and recall metrics
8. **Iterate gradually**: Make small adjustments based on operational feedback

---

## References

- [Google SRE Workbook: Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [SoundCloud: Alerting on SLOs like Pros](https://developers.soundcloud.com/blog/alerting-on-slos/)
- [Grafana: Multi-Window Multi-Burn-Rate Alerts](https://grafana.com/blog/2025/02/28/how-to-implement-multi-window-multi-burn-rate-alerts-with-grafana-cloud/)
- [Prometheus: Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
