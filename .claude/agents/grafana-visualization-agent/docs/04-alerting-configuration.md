# Grafana Alerting Configuration

**Purpose**: Comprehensive guide for Grafana unified alerting, provisioning alert rules, and notification policies.

**Last Updated**: 2025-11-28

---

## Overview

Grafana Unified Alerting (introduced in Grafana 8.0) provides:
- Multi-datasource alerting (Prometheus, Loki, Tempo, etc.)
- Flexible routing with notification policies
- Provisioning via YAML files
- Integration with external alerting systems

**Important**: This guide covers **Grafana-managed alerts**, not Prometheus Alertmanager or Loki/Mimir ruler alerts.

---

## Alerting Architecture

### Components

```
┌──────────────────────────────────────────┐
│          Grafana Unified Alerting       │
├──────────────────────────────────────────┤
│                                          │
│  ┌─────────────────────────────────┐   │
│  │      Alert Rules                 │   │
│  │  (queries + conditions)          │   │
│  └─────────────────────────────────┘   │
│               ↓                          │
│  ┌─────────────────────────────────┐   │
│  │   Alert Rule Evaluation          │   │
│  │  (every N seconds)               │   │
│  └─────────────────────────────────┘   │
│               ↓                          │
│  ┌─────────────────────────────────┐   │
│  │   Notification Policies          │   │
│  │  (routing + grouping)            │   │
│  └─────────────────────────────────┘   │
│               ↓                          │
│  ┌─────────────────────────────────┐   │
│  │      Contact Points              │   │
│  │  (email, Slack, PagerDuty, etc.) │   │
│  └─────────────────────────────────┘   │
│                                          │
└──────────────────────────────────────────┘
```

### Grafana vs. Backend Alerting

**Grafana-Managed Alerts** (this guide):
- Defined and evaluated in Grafana
- Multi-datasource queries
- Flexible notification routing
- Provisioned via Grafana provisioning files

**Data Source Alerts** (Prometheus/Loki/Mimir):
- Defined in datasource backend (alertmanager, ruler)
- Managed via datasource configuration
- Native to specific datasource

**Best Practice**: Use Grafana-managed alerts for multi-datasource correlation and centralized management.

---

## Alert Rules Provisioning

### Configuration Structure

```
config/grafana/provisioning/alerting/
├── alert_rules.yaml         # Alert rule definitions
├── contact_points.yaml      # Notification channels
├── notification_policies.yaml  # Routing configuration
└── templates.yaml           # Message templates (optional)
```

### Alert Rule YAML Structure

**File**: `provisioning/alerting/alert_rules.yaml`

```yaml
apiVersion: 1

groups:
  - orgId: 1
    name: service_alerts
    folder: Service Monitoring
    interval: 1m
    rules:
      - uid: high_error_rate
        title: High Error Rate
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: Mimir-Prometheus
            model:
              expr: |
                sum(rate(http_requests_total{status=~"5.."}[5m])) by (service) /
                sum(rate(http_requests_total[5m])) by (service) * 100
              refId: A
              intervalMs: 1000
              maxDataPoints: 43200
          - refId: B
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: "-100"
            model:
              type: reduce
              expr: ""
              reducer: last
              settings:
                mode: ""
              conditions:
                - evaluator:
                    params: []
                    type: gt
                  operator:
                    type: and
                  query:
                    params: []
                  reducer:
                    params: []
                    type: last
                  type: query
              refId: B
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: "-100"
            model:
              type: threshold
              expr: ""
              conditions:
                - evaluator:
                    params:
                      - 5
                    type: gt
                  operator:
                    type: and
                  query:
                    params:
                      - B
                  type: query
              refId: C
        noDataState: NoData
        execErrState: Error
        for: 5m
        annotations:
          description: "Service {{ $labels.service }} has error rate {{ $values.A.Value }}%"
          summary: "High error rate detected"
        labels:
          severity: warning
          team: backend
```

### Key Fields Explained

**Group Level**:
- **orgId** - Organization ID (1 for default)
- **name** - Alert group name (logical grouping)
- **folder** - Grafana folder for organization
- **interval** - Evaluation interval (e.g., `1m`, `30s`)

**Rule Level**:
- **uid** - Unique identifier for the rule
- **title** - Display name
- **condition** - refId of the condition query (usually last refId)
- **data** - Array of queries and conditions
- **noDataState** - Behavior when no data: `NoData`, `Alerting`, `OK`
- **execErrState** - Behavior on query error: `Error`, `Alerting`, `OK`
- **for** - Duration before alert fires (e.g., `5m`)
- **annotations** - Additional information (description, runbook URL)
- **labels** - Labels for routing and grouping

### Query Types (data array)

**1. Metric Query** (refId: A):

```yaml
- refId: A
  relativeTimeRange:
    from: 600      # 10 minutes ago
    to: 0          # now
  datasourceUid: Mimir-Prometheus
  model:
    expr: sum(rate(http_requests_total[5m])) by (service)
    refId: A
```

**2. Reduce/Math Expression** (refId: B):

```yaml
- refId: B
  datasourceUid: "-100"  # Built-in expression datasource
  model:
    type: reduce
    reducer: last      # last, min, max, mean, sum
    settings:
      mode: strict
    conditions: []
    refId: B
```

**3. Threshold Condition** (refId: C):

```yaml
- refId: C
  datasourceUid: "-100"
  model:
    type: threshold
    conditions:
      - evaluator:
          params: [5]    # Threshold value
          type: gt       # gt, gte, lt, lte, eq, neq
        operator:
          type: and      # and, or
        query:
          params: [B]    # Reference to previous query
        type: query
    refId: C
```

---

## Alert Rule Examples

### High Error Rate (Prometheus)

```yaml
groups:
  - orgId: 1
    name: service_health
    folder: Alerts
    interval: 1m
    rules:
      - uid: high_error_rate_alert
        title: High Error Rate
        condition: C
        data:
          # A: Query error rate
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: Mimir-Prometheus
            model:
              expr: |
                sum(rate(http_requests_total{status=~"5.."}[5m])) by (service) /
                sum(rate(http_requests_total[5m])) by (service) * 100
              refId: A
          # B: Reduce to last value
          - refId: B
            datasourceUid: "-100"
            model:
              type: reduce
              reducer: last
              refId: B
          # C: Threshold > 5%
          - refId: C
            datasourceUid: "-100"
            model:
              type: threshold
              conditions:
                - evaluator:
                    params: [5]
                    type: gt
                  query:
                    params: [B]
              refId: C
        noDataState: NoData
        execErrState: Error
        for: 5m
        annotations:
          description: |
            Service {{ $labels.service }} has {{ printf "%.2f" $values.A.Value }}% error rate.
            This exceeds the 5% threshold.
          runbook_url: https://wiki.example.com/runbooks/high-error-rate
        labels:
          severity: warning
          service: "{{ $labels.service }}"
          alert_type: error_rate
```

### High Latency (Prometheus)

```yaml
- uid: high_latency_alert
  title: High P95 Latency
  condition: C
  data:
    # A: Query P95 latency
    - refId: A
      relativeTimeRange:
        from: 600
        to: 0
      datasourceUid: Mimir-Prometheus
      model:
        expr: |
          histogram_quantile(0.95,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          )
        refId: A
    # B: Reduce to last value
    - refId: B
      datasourceUid: "-100"
      model:
        type: reduce
        reducer: last
        refId: B
    # C: Threshold > 1s
    - refId: C
      datasourceUid: "-100"
      model:
        type: threshold
        conditions:
          - evaluator:
              params: [1]
              type: gt
            query:
              params: [B]
        refId: C
  for: 10m
  annotations:
    description: |
      Service {{ $labels.service }} P95 latency is {{ printf "%.3f" $values.A.Value }}s
    summary: High latency detected
  labels:
    severity: warning
    alert_type: latency
```

### Error Logs (Loki)

```yaml
- uid: error_logs_alert
  title: High Error Log Rate
  condition: C
  data:
    # A: Count error logs
    - refId: A
      relativeTimeRange:
        from: 300
        to: 0
      datasourceUid: Loki
      model:
        expr: 'sum(count_over_time({job="api"} |= "ERROR" [5m]))'
        refId: A
    # B: Reduce to last value
    - refId: B
      datasourceUid: "-100"
      model:
        type: reduce
        reducer: last
        refId: B
    # C: Threshold > 100 errors
    - refId: C
      datasourceUid: "-100"
      model:
        type: threshold
        conditions:
          - evaluator:
              params: [100]
              type: gt
            query:
              params: [B]
        refId: C
  for: 5m
  annotations:
    description: "{{ $values.A.Value }} error logs in last 5 minutes"
    summary: High error log rate
  labels:
    severity: warning
    alert_type: logs
```

### Slow Traces (Tempo/TraceQL)

```yaml
- uid: slow_traces_alert
  title: Slow Trace Detection
  condition: C
  data:
    # A: Count slow traces
    - refId: A
      relativeTimeRange:
        from: 600
        to: 0
      datasourceUid: tempo
      model:
        queryType: traceql
        query: '{ service.name="api" && duration > 2s }'
        refId: A
    # B: Count traces
    - refId: B
      datasourceUid: "-100"
      model:
        type: reduce
        reducer: count
        refId: B
    # C: Threshold > 10 slow traces
    - refId: C
      datasourceUid: "-100"
      model:
        type: threshold
        conditions:
          - evaluator:
              params: [10]
              type: gt
            query:
              params: [B]
        refId: C
  for: 5m
  annotations:
    description: "{{ $values.B.Value }} traces slower than 2s detected"
  labels:
    severity: info
    alert_type: tracing
```

### LGTM Stack Component Down

```yaml
- uid: lgtm_component_down
  title: LGTM Component Down
  condition: C
  data:
    # A: Check component up metric
    - refId: A
      relativeTimeRange:
        from: 300
        to: 0
      datasourceUid: Mimir-Prometheus
      model:
        expr: 'up{job=~"loki|tempo|mimir"}'
        refId: A
    # B: Reduce to last value
    - refId: B
      datasourceUid: "-100"
      model:
        type: reduce
        reducer: last
        refId: B
    # C: Threshold < 1 (down)
    - refId: C
      datasourceUid: "-100"
      model:
        type: threshold
        conditions:
          - evaluator:
              params: [1]
              type: lt
            query:
              params: [B]
        refId: C
  for: 2m
  annotations:
    description: "LGTM component {{ $labels.job }} is down"
    summary: Critical observability component failure
  labels:
    severity: critical
    component: "{{ $labels.job }}"
    alert_type: infrastructure
```

---

## Contact Points (Notification Channels)

### Configuration File

**File**: `provisioning/alerting/contact_points.yaml`

```yaml
apiVersion: 1

contactPoints:
  - orgId: 1
    name: email-ops
    receivers:
      - uid: email_ops_receiver
        type: email
        settings:
          addresses: ops@example.com
        disableResolveMessage: false

  - orgId: 1
    name: slack-alerts
    receivers:
      - uid: slack_alerts_receiver
        type: slack
        settings:
          url: https://hooks.slack.com/services/YOUR/WEBHOOK/URL
          recipient: "#alerts"
          title: |
            {{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}
          text: |
            {{ range .Alerts }}
            *Alert:* {{ .Labels.alertname }}
            *Severity:* {{ .Labels.severity }}
            *Description:* {{ .Annotations.description }}
            {{ end }}
        disableResolveMessage: false

  - orgId: 1
    name: pagerduty-critical
    receivers:
      - uid: pagerduty_critical_receiver
        type: pagerduty
        settings:
          integrationKey: YOUR_PAGERDUTY_INTEGRATION_KEY
          severity: critical
          class: infrastructure
          component: monitoring
        disableResolveMessage: false

  - orgId: 1
    name: webhook-custom
    receivers:
      - uid: webhook_receiver
        type: webhook
        settings:
          url: https://api.example.com/webhooks/alerts
          httpMethod: POST
          authorization_scheme: Bearer
          authorization_credentials: YOUR_TOKEN
        disableResolveMessage: false
```

### Common Contact Point Types

**Email**:

```yaml
- type: email
  settings:
    addresses: team@example.com, oncall@example.com
    singleEmail: false  # Send separate emails or combine
```

**Slack**:

```yaml
- type: slack
  settings:
    url: https://hooks.slack.com/services/YOUR/WEBHOOK/URL
    recipient: "#alerts"
    mentionChannel: "here"  # @here, @channel, or empty
    token: ""  # Optional: For Slack API instead of webhook
```

**PagerDuty**:

```yaml
- type: pagerduty
  settings:
    integrationKey: YOUR_INTEGRATION_KEY
    severity: critical
    class: infrastructure
    component: api
    group: backend
```

**Microsoft Teams**:

```yaml
- type: teams
  settings:
    url: https://outlook.office.com/webhook/YOUR/WEBHOOK/URL
    title: "{{ .Status }}: {{ .Alerts.Firing | len }} alerts"
```

**Webhook (Generic)**:

```yaml
- type: webhook
  settings:
    url: https://api.example.com/alerts
    httpMethod: POST
    authorization_scheme: Bearer
    authorization_credentials: ${WEBHOOK_TOKEN}  # Use env var
```

**Discord**:

```yaml
- type: discord
  settings:
    url: https://discord.com/api/webhooks/YOUR/WEBHOOK
    message: |
      {{ len .Alerts.Firing }} firing alerts
    avatar_url: https://example.com/logo.png
    use_discord_username: false
```

---

## Notification Policies (Routing)

### Configuration File

**File**: `provisioning/alerting/notification_policies.yaml`

```yaml
apiVersion: 1

policies:
  - orgId: 1
    receiver: grafana-default  # Default/root receiver
    group_by: ['alertname', 'service']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      # Critical alerts to PagerDuty
      - receiver: pagerduty-critical
        object_matchers:
          - ['severity', '=', 'critical']
        continue: true  # Also send to other matching routes
        group_wait: 10s
        repeat_interval: 5m

      # Warning alerts to Slack
      - receiver: slack-alerts
        object_matchers:
          - ['severity', '=', 'warning']
        group_wait: 1m
        group_interval: 5m
        repeat_interval: 12h

      # Infrastructure alerts to ops email
      - receiver: email-ops
        object_matchers:
          - ['alert_type', '=', 'infrastructure']
        group_wait: 1m
        repeat_interval: 24h

      # Service-specific routing
      - receiver: slack-api-team
        object_matchers:
          - ['service', '=~', 'api.*']
          - ['severity', '=~', 'warning|critical']
        group_by: ['service', 'alertname']

      # Silence info alerts during business hours
      - receiver: "null"  # Discard
        object_matchers:
          - ['severity', '=', 'info']
        time_intervals:
          - business_hours
        continue: false
```

### Key Configuration Options

**Root Level**:
- **receiver** - Default contact point
- **group_by** - Labels to group alerts by
- **group_wait** - Wait before sending first notification (collect similar alerts)
- **group_interval** - Wait before sending about new alerts in existing group
- **repeat_interval** - Wait before re-sending resolved alerts

**Routes** (nested policies):
- **receiver** - Override contact point
- **object_matchers** - Label matching (routing criteria)
- **continue** - Continue to next matching route (default: false)
- **mute_time_intervals** - Don't send during these times

### Object Matchers

**Exact Match**:

```yaml
object_matchers:
  - ['severity', '=', 'critical']
```

**Regex Match**:

```yaml
object_matchers:
  - ['service', '=~', 'api.*']  # Starts with "api"
  - ['environment', '=~', 'prod|staging']  # Multiple values
```

**Not Equal**:

```yaml
object_matchers:
  - ['severity', '!=', 'info']
```

**Regex Not Match**:

```yaml
object_matchers:
  - ['alertname', '!~', 'Test.*']
```

**Multiple Matchers** (AND logic):

```yaml
object_matchers:
  - ['severity', '=', 'critical']
  - ['service', '=', 'api']
  - ['environment', '=', 'prod']
```

---

## Mute Timings

### Configuration

**File**: `provisioning/alerting/mute_timings.yaml`

```yaml
apiVersion: 1

muteTimes:
  - orgId: 1
    name: business_hours
    time_intervals:
      - times:
          - start_time: '09:00'
            end_time: '17:00'
        weekdays: ['monday:friday']

  - orgId: 1
    name: weekends
    time_intervals:
      - weekdays: ['saturday', 'sunday']

  - orgId: 1
    name: maintenance_window
    time_intervals:
      - times:
          - start_time: '02:00'
            end_time: '04:00'
        weekdays: ['sunday']
        days_of_month: ['1', '15']  # 1st and 15th of month
```

### Usage in Notification Policies

```yaml
routes:
  - receiver: slack-alerts
    object_matchers:
      - ['severity', '=', 'warning']
    mute_time_intervals:
      - business_hours  # Don't send warnings during business hours
```

---

## Message Templates

### Configuration

**File**: `provisioning/alerting/templates.yaml`

```yaml
apiVersion: 1

templates:
  - orgId: 1
    name: custom_message
    template: |
      {{ define "custom_alert" }}
      *Status:* {{ .Status | toUpper }}
      *Alert:* {{ .Labels.alertname }}
      *Severity:* {{ .Labels.severity }}
      *Service:* {{ .Labels.service }}

      {{ range .Alerts }}
      *Description:* {{ .Annotations.description }}
      *Value:* {{ .Values }}
      *Started:* {{ .StartsAt.Format "2006-01-02 15:04:05" }}
      {{ if .Annotations.runbook_url }}
      *Runbook:* {{ .Annotations.runbook_url }}
      {{ end }}
      {{ end }}
      {{ end }}
```

### Template Variables

**Available Variables**:
- `{{ .Status }}` - "firing" or "resolved"
- `{{ .Labels }}` - Alert labels
- `{{ .Annotations }}` - Alert annotations
- `{{ .Values }}` - Query result values
- `{{ .StartsAt }}` - Alert start time
- `{{ .EndsAt }}` - Alert end time (resolved)
- `{{ .Alerts }}` - List of alerts in group
- `{{ .Alerts.Firing }}` - Firing alerts
- `{{ .Alerts.Resolved }}` - Resolved alerts

**Template Functions**:
- `{{ .Status | toUpper }}` - FIRING or RESOLVED
- `{{ .Alerts.Firing | len }}` - Count of firing alerts
- `{{ printf "%.2f" .Value }}` - Format float
- `{{ .StartsAt.Format "2006-01-02 15:04:05" }}` - Format timestamp

---

## Alerting Best Practices

### 1. Alert on Symptoms, Not Causes

**Good**: "Error rate > 5%" (user-facing symptom)
**Bad**: "Disk usage > 80%" (cause, may not affect users)

### 2. Set Appropriate "for" Duration

```yaml
# Critical - fast response
for: 2m

# Warning - avoid noise
for: 10m

# Info - significant duration
for: 30m
```

### 3. Use Meaningful Labels

```yaml
labels:
  severity: critical      # For routing
  alert_type: error_rate  # For categorization
  service: "{{ $labels.service }}"  # Include context
  team: backend           # For assignment
  environment: prod       # For filtering
```

### 4. Write Actionable Annotations

```yaml
annotations:
  description: |
    Service {{ $labels.service }} has {{ printf "%.2f" $values.A.Value }}% error rate.
    This exceeds the 5% SLO threshold.
  summary: High error rate on {{ $labels.service }}
  runbook_url: https://wiki.example.com/runbooks/high-error-rate
  dashboard_url: https://grafana.example.com/d/service-red/{{ $labels.service }}
```

### 5. Implement Routing Hierarchy

```
Critical → PagerDuty (immediate)
Warning → Slack (grouped)
Info → Email (daily digest)
```

### 6. Group Related Alerts

```yaml
group_by: ['alertname', 'service', 'environment']
group_wait: 30s  # Collect similar alerts
group_interval: 5m  # Wait before sending more
```

### 7. Avoid Alert Fatigue

- Set appropriate thresholds (not too sensitive)
- Use `for` duration to avoid flapping
- Mute non-actionable alerts during known maintenance
- Use `continue: false` to stop processing when appropriate

---

## Testing Alerts

### Manual Testing

**1. UI Testing**:
- Grafana > Alerting > Alert rules
- Click "Test rule"
- Verify condition evaluation

**2. API Testing**:

```bash
# Test alert rule
curl -X POST http://localhost:3000/api/v1/eval \
  -H "Content-Type: application/json" \
  -u admin:admin \
  -d '{
    "queries": [{
      "refId": "A",
      "expr": "sum(rate(http_requests_total[5m]))",
      "datasourceUid": "Mimir-Prometheus"
    }]
  }'
```

**3. Force Alert State**:

```yaml
# Temporarily lower threshold to trigger alert
conditions:
  - evaluator:
      params: [0.01]  # Very low threshold
      type: gt
```

### Monitoring Alert Manager

```promql
# Alert manager health
up{job="grafana"}

# Alerts firing
grafana_alerting_active_alerts

# Notification successes/failures
grafana_alerting_notifications_sent_total
grafana_alerting_notifications_failed_total
```

---

## Troubleshooting

### Alerts Not Firing

**Check**:
1. Alert rule evaluation: Grafana > Alerting > Alert rules (view state)
2. Query returns data: Test in Explore
3. Condition is met: Check threshold values
4. `for` duration not elapsed yet
5. Alert not muted

**Logs**:

```bash
docker compose logs grafana | grep -i alert
```

### Notifications Not Sent

**Check**:
1. Contact point configured correctly
2. Notification policy routing matches labels
3. Alert has required labels for routing
4. Not muted by time interval
5. Contact point credentials valid

**Test Contact Point**:

Grafana > Alerting > Contact points > Test

### Alert Flapping

**Symptoms**: Alert constantly firing and resolving

**Solutions**:
- Increase `for` duration
- Add hysteresis (separate thresholds for firing/resolving)
- Smooth data with longer rate windows
- Filter outliers

---

## Complete Example Configuration

### Directory Structure

```
provisioning/alerting/
├── alert_rules.yaml
├── contact_points.yaml
├── notification_policies.yaml
├── mute_timings.yaml
└── templates.yaml
```

### Minimal Working Example

**alert_rules.yaml**:

```yaml
apiVersion: 1
groups:
  - orgId: 1
    name: basic_alerts
    folder: Alerts
    interval: 1m
    rules:
      - uid: basic_error_rate
        title: Basic Error Rate Alert
        condition: B
        data:
          - refId: A
            datasourceUid: Mimir-Prometheus
            model:
              expr: 'sum(rate(http_requests_total{status=~"5.."}[5m])) > 10'
          - refId: B
            datasourceUid: "-100"
            model:
              type: threshold
              conditions:
                - evaluator:
                    params: [0]
                    type: gt
        for: 5m
        annotations:
          description: "Error rate exceeds threshold"
        labels:
          severity: warning
```

**contact_points.yaml**:

```yaml
apiVersion: 1
contactPoints:
  - orgId: 1
    name: email-default
    receivers:
      - type: email
        settings:
          addresses: alerts@example.com
```

**notification_policies.yaml**:

```yaml
apiVersion: 1
policies:
  - orgId: 1
    receiver: email-default
    group_by: ['alertname']
    group_wait: 30s
    repeat_interval: 4h
```

---

## Reference

**Official Documentation**:
- Grafana Alerting: https://grafana.com/docs/grafana/latest/alerting/
- Provisioning alerts: https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/
- Alert rule API: https://grafana.com/docs/grafana/latest/developers/http_api/alerting/

**Examples**:
- GitHub examples: https://github.com/grafana/provisioning-alerting-examples

**Current Project**:
- Provisioning directory: `config/grafana/provisioning/alerting/`
- Create directory if not exists: `mkdir -p config/grafana/provisioning/alerting`
