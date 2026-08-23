# Notification Routing: Alertmanager Configuration and Escalation

**Created:** 2025-11-28
**Purpose:** Comprehensive guide to Alertmanager configuration, notification routing, grouping, inhibition, and escalation patterns

---

## Table of Contents

1. [Alertmanager Fundamentals](#alertmanager-fundamentals)
2. [Configuration Structure](#configuration-structure)
3. [Routing Tree Design](#routing-tree-design)
4. [Grouping Strategies](#grouping-strategies)
5. [Inhibition Rules](#inhibition-rules)
6. [Receiver Configuration](#receiver-configuration)
7. [Time-Based Routing](#time-based-routing)
8. [Escalation Patterns](#escalation-patterns)
9. [Template Customization](#template-customization)
10. [Best Practices](#best-practices)

---

## Alertmanager Fundamentals

### Purpose

Alertmanager handles alerts sent from Prometheus/Mimir/Loki rulers. It provides:

1. **Deduplication**: Prevents duplicate notifications for the same alert
2. **Grouping**: Combines related alerts into single notifications
3. **Routing**: Directs alerts to appropriate teams/channels
4. **Silencing**: Temporarily mutes alerts during maintenance
5. **Inhibition**: Suppresses alerts based on other active alerts

### Alert Flow

```
Prometheus/Mimir/Loki → Alertmanager → Receivers (Email, Slack, PagerDuty, etc.)
         ↓                    ↓
   Alerting Rules      Route Matching
                       Grouping
                       Inhibition
                       Silencing
```

### Configuration Location

**Standalone Alertmanager:**
```yaml
# alertmanager.yml
global:
  resolve_timeout: 5m

route:
  receiver: 'default'
  # ...

receivers:
  - name: 'default'
    # ...
```

**Mimir Embedded Alertmanager:**
```yaml
# mimir-config.yaml
alertmanager:
  data_dir: /data/alertmanager
  external_url: http://localhost:9009/alertmanager

# Rules configured via ruler API
# Alertmanager config uploaded via API
```

---

## Configuration Structure

### Complete Example

```yaml
global:
  # How long to wait before sending a notification about new alert
  resolve_timeout: 5m

  # SMTP settings for email notifications
  smtp_from: 'alertmanager@example.com'
  smtp_smarthost: 'smtp.example.com:587'
  smtp_auth_username: 'alertmanager@example.com'
  smtp_auth_password: 'password'
  smtp_require_tls: true

  # Slack API URL
  slack_api_url: 'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX'

  # PagerDuty API URL
  pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'

# Templates for notification content
templates:
  - '/etc/alertmanager/templates/*.tmpl'

# Root route - all alerts enter here
route:
  receiver: 'default'
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 4h

  # Child routes for specific routing logic
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-critical'
      group_wait: 10s
      repeat_interval: 5m
      continue: true

    - match:
        severity: warning
      receiver: 'slack-warnings'
      group_wait: 30s
      repeat_interval: 12h

    - match:
        team: database
      receiver: 'slack-database-team'

# Notification receivers
receivers:
  - name: 'default'
    slack_configs:
      - channel: '#alerts-default'
        title: 'Alert: {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}\n{{ end }}'

  - name: 'pagerduty-critical'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_SERVICE_KEY'

  - name: 'slack-warnings'
    slack_configs:
      - channel: '#alerts-warnings'

  - name: 'slack-database-team'
    slack_configs:
      - channel: '#team-database'

# Inhibition rules - suppress alerts based on other alerts
inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'cluster', 'service']

  - source_match:
      alertname: 'InstanceDown'
    target_match_re:
      alertname: 'HighErrorRate|HighLatency'
    equal: ['instance']
```

---

## Routing Tree Design

### How Routing Works

1. **All alerts enter root route**: Every alert starts at the top-level route
2. **Match against child routes**: Alert tested against each child route's matchers
3. **First match wins**: Unless `continue: true` is set
4. **Inherit parent settings**: Child routes inherit group_by, timings from parent unless overridden

### Basic Routing by Severity

```yaml
route:
  receiver: 'default'
  group_by: ['alertname', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

  routes:
    # Critical alerts → Page on-call
    - match:
        severity: critical
      receiver: 'pagerduty-oncall'
      group_wait: 10s
      repeat_interval: 5m

    # Warning alerts → Slack during business hours
    - match:
        severity: warning
      receiver: 'slack-platform'
      group_wait: 30s
      repeat_interval: 12h

    # Info alerts → Create Jira ticket
    - match:
        severity: info
      receiver: 'jira-tickets'
      group_wait: 5m
      repeat_interval: 24h
```

### Routing by Team

```yaml
route:
  receiver: 'default'
  routes:
    # Platform team alerts
    - match:
        team: platform
      receiver: 'slack-platform'
      routes:
        # Platform critical → Page platform on-call
        - match:
            severity: critical
          receiver: 'pagerduty-platform'

    # Database team alerts
    - match:
        team: database
      receiver: 'slack-database'
      routes:
        # Database critical → Page database on-call
        - match:
            severity: critical
          receiver: 'pagerduty-database'

    # Security team alerts
    - match:
        team: security
      receiver: 'slack-security'
      routes:
        # Security incidents → Page security immediately
        - match:
            priority: p1
          receiver: 'pagerduty-security'
```

### Routing by Component

```yaml
route:
  receiver: 'default'
  routes:
    # Frontend alerts → Frontend team
    - match:
        component: frontend
      receiver: 'slack-frontend'

    # API alerts → Backend team
    - match:
        component: api
      receiver: 'slack-backend'

    # Database alerts → Database team
    - match:
        component: database
      receiver: 'slack-database'

    # Ingester/Querier alerts → Platform team
    - match_re:
        component: 'ingester|querier|distributor|compactor'
      receiver: 'slack-platform'
```

### Multi-Destination Routing with `continue`

Use `continue: true` to send alert to multiple receivers:

```yaml
route:
  receiver: 'default'
  routes:
    # Critical alerts → BOTH PagerDuty AND Slack
    - match:
        severity: critical
      receiver: 'pagerduty-oncall'
      continue: true  # Continue to next matching route

    - match:
        severity: critical
      receiver: 'slack-critical'
      # No continue here - stops processing
```

---

## Grouping Strategies

### What is Grouping?

Grouping combines multiple related alerts into a single notification to reduce alert noise.

**Example:**
- Without grouping: 10 separate notifications for "HighMemory" on 10 different instances
- With grouping: 1 notification listing all 10 affected instances

### Group By Labels

```yaml
route:
  group_by: ['alertname', 'cluster', 'service']
```

**Result:** Alerts with same `alertname`, `cluster`, and `service` grouped together.

### Timing Parameters

```yaml
route:
  group_wait: 10s       # Wait this long before sending first notification
  group_interval: 5m    # Wait this long before sending update about new alerts in group
  repeat_interval: 4h   # How often to resend notification for unresolved alerts
```

**Example timeline:**

```
00:00 - Alert1 fires
00:10 - First notification sent (after group_wait)
00:15 - Alert2 fires (same group)
00:20 - Update sent with Alert2 (after group_interval)
04:20 - Reminder sent (after repeat_interval)
```

### Grouping Patterns

**Group by alert type:**
```yaml
group_by: ['alertname']
# All HighErrorRate alerts grouped together across all services
```

**Group by service:**
```yaml
group_by: ['service']
# All alerts for 'api' service grouped together
```

**Group by severity:**
```yaml
group_by: ['alertname', 'severity']
# HighErrorRate critical and HighErrorRate warning sent separately
```

**No grouping (send individually):**
```yaml
group_by: ['...']  # Special value meaning "all labels"
# Each unique combination of labels = separate notification
```

### Best Practices for Grouping

1. **Critical alerts**: Short `group_wait` (10s), frequent `repeat_interval` (5m)
2. **Warning alerts**: Medium `group_wait` (30s), moderate `repeat_interval` (1h)
3. **Info alerts**: Long `group_wait` (5m), infrequent `repeat_interval` (12h+)

---

## Inhibition Rules

### Purpose

Inhibition suppresses target alerts when source alerts are active. Prevents cascading alert storms.

### Basic Structure

```yaml
inhibit_rules:
  - source_match:      # If this alert is firing...
      severity: 'critical'
    target_match:      # Suppress these alerts...
      severity: 'warning'
    equal:             # When these labels match
      - 'alertname'
      - 'service'
```

**Logic:** If critical alert for "api" service is firing, suppress warning alerts for "api" service with same alertname.

### Common Patterns

**Suppress lower severity alerts:**

```yaml
inhibit_rules:
  # Critical suppresses warning
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'service']

  # Warning suppresses info
  - source_match:
      severity: 'warning'
    target_match:
      severity: 'info'
    equal: ['alertname', 'service']
```

**Suppress downstream alerts when upstream fails:**

```yaml
inhibit_rules:
  # Database down → Suppress API alerts
  - source_match:
      alertname: 'DatabaseDown'
    target_match_re:
      alertname: 'HighErrorRate|HighLatency'
      component: 'api'
    equal: ['cluster']

  # Instance down → Suppress all alerts from that instance
  - source_match:
      alertname: 'InstanceDown'
    target_match_re:
      alertname: '.*'
    equal: ['instance']

  # Network partition → Suppress unreachable alerts
  - source_match:
      alertname: 'NetworkPartition'
    target_match:
      alertname: 'InstanceUnreachable'
    equal: ['cluster', 'datacenter']
```

**Suppress SLO alerts when underlying metrics missing:**

```yaml
inhibit_rules:
  # No metrics → Don't alert on SLO breach
  - source_match:
      alertname: 'MetricsCollectionFailed'
    target_match:
      alert_type: 'error_budget_burn'
    equal: ['service']
```

### Regex Matching

Use `target_match_re` for pattern matching:

```yaml
inhibit_rules:
  - source_match:
      alertname: 'ClusterDown'
    target_match_re:
      alertname: 'High.*|Low.*|.*Degraded'  # Matches any alert containing these patterns
    equal: ['cluster']
```

---

## Receiver Configuration

### Email Receiver

```yaml
receivers:
  - name: 'email-team'
    email_configs:
      - to: 'team@example.com'
        from: 'alertmanager@example.com'
        smarthost: 'smtp.example.com:587'
        auth_username: 'alertmanager@example.com'
        auth_password: 'password'
        require_tls: true
        headers:
          Subject: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        html: |
          <h2>Alert: {{ .GroupLabels.alertname }}</h2>
          <p><strong>Status:</strong> {{ .Status }}</p>
          <ul>
          {{ range .Alerts }}
            <li>{{ .Annotations.summary }}</li>
          {{ end }}
          </ul>
```

### Slack Receiver

```yaml
receivers:
  - name: 'slack-alerts'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXX'
        channel: '#alerts'
        username: 'Alertmanager'
        icon_emoji: ':warning:'
        title: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'
        text: |
          {{ range .Alerts }}
          *Summary:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          *Severity:* {{ .Labels.severity }}
          *Service:* {{ .Labels.service }}
          *Runbook:* {{ .Annotations.runbook_url }}
          {{ end }}
        send_resolved: true
        color: '{{ if eq .Status "firing" }}danger{{ else }}good{{ end }}'
```

### PagerDuty Receiver

```yaml
receivers:
  - name: 'pagerduty-oncall'
    pagerduty_configs:
      - service_key: 'YOUR_PAGERDUTY_INTEGRATION_KEY'
        description: '{{ .GroupLabels.alertname }} - {{ .GroupLabels.service }}'
        severity: '{{ .CommonLabels.severity }}'
        details:
          firing: '{{ .Alerts.Firing | len }}'
          resolved: '{{ .Alerts.Resolved | len }}'
          num_alerts: '{{ .Alerts | len }}'
        links:
          - href: '{{ .CommonAnnotations.runbook_url }}'
            text: 'Runbook'
          - href: '{{ .CommonAnnotations.dashboard_url }}'
            text: 'Dashboard'
```

### Webhook Receiver (Custom Integration)

```yaml
receivers:
  - name: 'webhook-jira'
    webhook_configs:
      - url: 'https://api.example.com/alerts/create-ticket'
        send_resolved: true
        http_config:
          basic_auth:
            username: 'api-user'
            password: 'api-password'
```

### OpsGenie Receiver

```yaml
receivers:
  - name: 'opsgenie-oncall'
    opsgenie_configs:
      - api_key: 'YOUR_OPSGENIE_API_KEY'
        message: '{{ .GroupLabels.alertname }}'
        description: '{{ .CommonAnnotations.summary }}'
        priority: '{{ .CommonLabels.severity }}'
        tags: '{{ .CommonLabels.team }},{{ .CommonLabels.component }}'
```

### Multiple Receivers

Send to multiple destinations:

```yaml
receivers:
  - name: 'multi-receiver'
    slack_configs:
      - channel: '#alerts'
        # Slack config...
    email_configs:
      - to: 'oncall@example.com'
        # Email config...
    pagerduty_configs:
      - service_key: 'KEY'
        # PagerDuty config...
```

---

## Time-Based Routing

### Business Hours vs After-Hours

Route alerts differently based on time of day:

```yaml
# Define time intervals
time_intervals:
  - name: 'business_hours'
    time_intervals:
      - times:
          - start_time: '09:00'
            end_time: '17:00'
        weekdays: ['monday:friday']
        location: 'America/New_York'

  - name: 'after_hours'
    time_intervals:
      - times:
          - start_time: '17:00'
            end_time: '09:00'
        weekdays: ['monday:friday']
      - times:
          - start_time: '00:00'
            end_time: '23:59'
        weekdays: ['saturday', 'sunday']
        location: 'America/New_York'

# Use time intervals in routing
route:
  receiver: 'default'
  routes:
    # During business hours → Slack
    - match:
        severity: warning
      receiver: 'slack-warnings'
      active_time_intervals:
        - business_hours

    # After hours → PagerDuty
    - match:
        severity: warning
      receiver: 'pagerduty-oncall'
      active_time_intervals:
        - after_hours
```

### Maintenance Windows

Mute alerts during scheduled maintenance:

```yaml
time_intervals:
  - name: 'maintenance_window'
    time_intervals:
      - times:
          - start_time: '02:00'
            end_time: '04:00'
        weekdays: ['sunday']
        location: 'UTC'

route:
  receiver: 'default'
  routes:
    - match:
        component: database
      receiver: 'slack-database'
      mute_time_intervals:
        - maintenance_window  # Mute during maintenance
```

---

## Escalation Patterns

### Progressive Escalation

Escalate to higher severity if alert persists:

**Strategy:** Use alert `for` duration and multiple burn rates

```yaml
# In Prometheus/Mimir rules
- alert: ErrorBudgetBurn_Low
  expr: burn_rate > 3
  for: 1h
  labels:
    severity: warning

- alert: ErrorBudgetBurn_High
  expr: burn_rate > 6
  for: 15m
  labels:
    severity: critical
```

**Routing:**
```yaml
route:
  routes:
    - match:
        severity: warning
      receiver: 'slack-warnings'

    - match:
        severity: critical
      receiver: 'pagerduty-oncall'
```

### Multi-Tier On-Call

Route to different on-call teams based on priority:

```yaml
receivers:
  - name: 'pagerduty-tier1'
    pagerduty_configs:
      - service_key: 'TIER1_KEY'

  - name: 'pagerduty-tier2'
    pagerduty_configs:
      - service_key: 'TIER2_KEY'

  - name: 'pagerduty-tier3'
    pagerduty_configs:
      - service_key: 'TIER3_KEY'

route:
  routes:
    # P1 → Tier 1 (senior engineers)
    - match:
        priority: p1
      receiver: 'pagerduty-tier1'
      repeat_interval: 5m

    # P2 → Tier 2 (mid-level engineers)
    - match:
        priority: p2
      receiver: 'pagerduty-tier2'
      repeat_interval: 15m

    # P3 → Tier 3 (junior engineers)
    - match:
        priority: p3
      receiver: 'pagerduty-tier3'
      repeat_interval: 1h
```

### Follow-the-Sun Routing

Route to different teams based on timezone:

```yaml
time_intervals:
  - name: 'us_hours'
    time_intervals:
      - times:
          - start_time: '09:00'
            end_time: '17:00'
        location: 'America/New_York'

  - name: 'eu_hours'
    time_intervals:
      - times:
          - start_time: '09:00'
            end_time: '17:00'
        location: 'Europe/London'

  - name: 'apac_hours'
    time_intervals:
      - times:
          - start_time: '09:00'
            end_time: '17:00'
        location: 'Asia/Singapore'

route:
  routes:
    - match:
        severity: critical
      receiver: 'pagerduty-us'
      active_time_intervals:
        - us_hours

    - match:
        severity: critical
      receiver: 'pagerduty-eu'
      active_time_intervals:
        - eu_hours

    - match:
        severity: critical
      receiver: 'pagerduty-apac'
      active_time_intervals:
        - apac_hours
```

---

## Template Customization

### Defining Templates

Create custom templates in separate files:

```go
{{ define "slack.title" }}
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.alertname }}
{{ end }}

{{ define "slack.text" }}
{{ range .Alerts }}
*Alert:* {{ .Labels.alertname }}
*Severity:* {{ .Labels.severity }}
*Service:* {{ .Labels.service }}
*Summary:* {{ .Annotations.summary }}
*Description:* {{ .Annotations.description }}
{{ if .Annotations.runbook_url }}*Runbook:* {{ .Annotations.runbook_url }}{{ end }}
{{ if .Annotations.dashboard_url }}*Dashboard:* {{ .Annotations.dashboard_url }}{{ end }}
---
{{ end }}
{{ end }}
```

### Using Templates

Reference templates in receiver configs:

```yaml
templates:
  - '/etc/alertmanager/templates/*.tmpl'

receivers:
  - name: 'slack-custom'
    slack_configs:
      - channel: '#alerts'
        title: '{{ template "slack.title" . }}'
        text: '{{ template "slack.text" . }}'
```

### Template Data Structure

Available data in templates:

```go
.Status           // "firing" or "resolved"
.Alerts           // List of all alerts
.Alerts.Firing    // List of firing alerts
.Alerts.Resolved  // List of resolved alerts
.GroupLabels      // Labels used for grouping
.CommonLabels     // Labels common to all alerts
.CommonAnnotations // Annotations common to all alerts
.ExternalURL      // Alertmanager external URL

// For each alert:
.Labels           // Alert labels
.Annotations      // Alert annotations
.StartsAt         // When alert started firing
.EndsAt           // When alert resolved
.GeneratorURL     // Link to Prometheus expression
```

### Advanced Template Example

```go
{{ define "email.subject" }}
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.alertname }}
{{ end }}

{{ define "email.html" }}
<!DOCTYPE html>
<html>
<head>
  <style>
    body { font-family: Arial, sans-serif; }
    .firing { color: #d32f2f; }
    .resolved { color: #388e3c; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    th { background-color: #f2f2f2; }
  </style>
</head>
<body>
  <h2 class="{{ .Status }}">{{ .Status | toUpper }}: {{ .GroupLabels.alertname }}</h2>

  <h3>Summary</h3>
  <ul>
    <li><strong>Status:</strong> {{ .Status }}</li>
    <li><strong>Severity:</strong> {{ .CommonLabels.severity }}</li>
    <li><strong>Affected Service:</strong> {{ .CommonLabels.service }}</li>
    <li><strong>Total Alerts:</strong> {{ .Alerts | len }}</li>
  </ul>

  <h3>Details</h3>
  <table>
    <tr>
      <th>Alert</th>
      <th>Instance</th>
      <th>Summary</th>
      <th>Started</th>
    </tr>
    {{ range .Alerts }}
    <tr>
      <td>{{ .Labels.alertname }}</td>
      <td>{{ .Labels.instance }}</td>
      <td>{{ .Annotations.summary }}</td>
      <td>{{ .StartsAt }}</td>
    </tr>
    {{ end }}
  </table>

  <p><a href="{{ .CommonAnnotations.runbook_url }}">View Runbook</a></p>
  <p><a href="{{ .CommonAnnotations.dashboard_url }}">View Dashboard</a></p>
</body>
</html>
{{ end }}
```

---

## Best Practices

### Routing Design

1. **Start with severity-based routing**: Critical → Page, Warning → Slack, Info → Ticket
2. **Add team-based routing**: Route by ownership labels
3. **Use `continue` sparingly**: Too many receivers creates noise
4. **Test routing logic**: Verify alerts reach intended destinations

### Grouping Strategy

1. **Group related alerts**: Use `alertname` + `service` as baseline
2. **Balance noise vs detail**: Too much grouping hides important information
3. **Adjust timing for urgency**: Critical alerts need fast `group_wait` and `repeat_interval`
4. **Consider time zones**: Increase `repeat_interval` for non-critical alerts at night

### Inhibition Rules

1. **Suppress cascading failures**: Database down should suppress API errors
2. **Suppress lower severities**: Critical alerts hide warnings for same issue
3. **Test inhibition logic**: Verify suppressions work as expected
4. **Document dependencies**: Make it clear which alerts suppress others

### Receiver Configuration

1. **Use templates**: Consistent formatting across receivers
2. **Include context**: Summary, description, runbook, dashboard links
3. **Send resolved notifications**: Close the loop with on-call engineers
4. **Test integrations**: Verify each receiver works before deploying

### Template Design

1. **Keep it simple**: Overly complex templates are hard to debug
2. **Provide actionable information**: What's wrong? Where to look? What to do?
3. **Link to resources**: Runbooks, dashboards, documentation
4. **Format for readability**: Use tables, lists, spacing

### Maintenance

1. **Review routing rules quarterly**: Remove unused routes, adjust based on feedback
2. **Monitor alert volume**: High volume indicates routing or alert design issues
3. **Collect feedback**: Ask on-call engineers what's working and what's not
4. **Version control**: Keep alertmanager.yml in git, review changes

---

## Configuration for LGTM Stack

### Mimir Embedded Alertmanager

```yaml
# In mimir-config.yaml
alertmanager:
  data_dir: /data/alertmanager
  external_url: http://localhost:9009/alertmanager
  # Alertmanager config uploaded via API or stored in backend
```

**Upload config via API:**

```bash
curl -X POST http://localhost:9009/alertmanager/api/v1/alerts \
  -H "Content-Type: application/yaml" \
  --data-binary @alertmanager.yml
```

### Loki Ruler with Alertmanager

```yaml
# In loki-config.yaml
ruler:
  alertmanager_url: 'http://alertmanager:9093'
  # Or use Mimir embedded Alertmanager
  # alertmanager_url: 'http://mimir:9009/alertmanager'
```

---

## References

- [Prometheus Alertmanager Configuration](https://prometheus.io/docs/alerting/latest/configuration/)
- [Grafana Mimir Alertmanager](https://grafana.com/docs/mimir/latest/references/architecture/components/alertmanager/)
- [Alertmanager Notification Templates](https://prometheus.io/docs/alerting/latest/notification_examples/)
- [Google SRE: Practical Alerting](https://sre.google/sre-book/practical-alerting/)
