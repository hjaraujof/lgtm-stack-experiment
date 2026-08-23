# Alerting and SRE Patterns Documentation

**Agent:** alerting-sre-patterns-agent
**Created:** 2025-11-28
**Purpose:** Comprehensive documentation on alerting patterns, SLO/SLI definitions, and SRE best practices for the LGTM stack

---

## Overview

This documentation provides expert guidance on implementing production-grade alerting and SRE patterns using:

- **Grafana Loki** - Log aggregation with LogQL alerting
- **Grafana Mimir** - Prometheus-compatible metrics with PromQL alerting
- **Grafana Tempo** - Distributed tracing
- **Alertmanager** - Alert routing, grouping, and notification

The patterns documented here follow Google SRE best practices, particularly the multi-window multi-burn-rate alerting methodology for SLO-based alerting.

---

## Documentation Structure

### [01. Alert Rule Design](./01-alert-rule-design.md)

**Topics covered:**
- Alert rule fundamentals (expressions, conditions, durations, labels, annotations)
- LogQL alert patterns for Loki (error rate detection, credential leaks, log volume spikes)
- PromQL alert patterns for Mimir (latency, error rates, resource usage, instance health)
- Alert configuration structure (rule groups, ruler configuration)
- Duration and threshold configuration (`for` clause, `keep_firing_for`)
- Annotations and labels best practices (severity levels, templating, runbook URLs)
- Alert state management (inactive → pending → firing → resolved)

**Key examples:**
- High error rate detection from logs
- Credential leak security alerts
- HTTP latency monitoring with histograms
- Memory and CPU threshold alerts
- Service instance health checks

**When to use:** Designing new alerting rules or troubleshooting existing alerts

---

### [02. SLO/SLI Patterns](./02-slo-sli-patterns.md)

**Topics covered:**
- SLO/SLI fundamentals (definitions, error budgets, the Golden Signals)
- Common SLI types (availability, latency, data freshness, durability, throughput)
- SLO target setting (the 9s framework, 99% to 99.999%)
- Error budget calculation and consumption tracking
- SLI implementation patterns (counter-based, histogram-based, log-based)
- Recording rules for SLIs (pre-computation for performance)
- SLO-based alerting strategy (alert on budget risk, not symptoms)
- Low-traffic service challenges and solutions

**Key examples:**
- Availability SLI: `successful_requests / total_requests`
- Latency SLI: `fast_requests / total_requests`
- Multi-window SLI recording rules
- Error budget policies (deployment freezes based on budget consumption)

**When to use:** Defining service reliability targets, implementing SLO tracking, setting up error budget policies

---

### [03. Multi-Window Multi-Burn-Rate Alerting](./03-multi-burn-rate-alerting.md)

**Topics covered:**
- Core concepts (why Google SRE evolved to this approach)
- Why multiple windows (balance detection speed with low false positives)
- Burn rate calculation (how fast you're consuming error budget)
- Recommended alert tiers (14.4x, 6x, 3x, 1x burn rates)
- Complete implementation example (from metrics to alerts)
- PromQL implementation (availability and latency patterns)
- LogQL implementation (log-based SLO tracking)
- Recording rules setup (error rate and burn rate pre-computation)
- Alert configuration (four-tier alerting with proper annotations)
- Operational patterns (tuning, alert storms, progressive escalation)

**Key examples:**
- High-burn page alert (14.4x, 1h/5m windows) - consumes 2% budget/hour
- Medium-burn page alert (6x, 6h/30m windows) - consumes 5% budget in 6 hours
- Complete recording rule set for burn rate calculation
- Four-tier alert configuration (critical, high, medium, low)

**When to use:** Implementing Google SRE's recommended alerting approach, replacing symptom-based alerts with SLO-based alerts

---

### [04. Recording Rules](./04-recording-rules.md)

**Topics covered:**
- Recording rules fundamentals (pre-computation, when results appear)
- Why recording rules (performance, consistency, enabling complex alerting)
- Naming conventions (`level:metric:operations` pattern)
- Common patterns (availability, error rate, latency percentiles, request rate)
- SLO recording rules (multi-window SLI sets, error budget tracking)
- Performance recording rules (request aggregations, latency aggregations)
- Aggregation recording rules (cross-service, per-endpoint)
- Best practices (rule group organization, minimizing cardinality)
- Testing and validation (syntax checking, result comparison)

**Key examples:**
- Complete multi-window SLI recording rule set (5m, 30m, 1h, 2h, 6h, 1d, 3d, 30d)
- Burn rate calculation recording rules
- Latency percentile pre-computation (P50, P95, P99, P99.9)
- Cluster-wide and per-endpoint aggregations

**When to use:** Improving dashboard performance, preparing for multi-window alerting, standardizing metric definitions

---

### [05. Notification Routing](./05-notification-routing.md)

**Topics covered:**
- Alertmanager fundamentals (deduplication, grouping, routing, silencing, inhibition)
- Configuration structure (global settings, routing tree, receivers, inhibition rules)
- Routing tree design (severity-based, team-based, component-based, multi-destination)
- Grouping strategies (group_by labels, timing parameters, grouping patterns)
- Inhibition rules (suppressing cascading alerts, regex matching)
- Receiver configuration (email, Slack, PagerDuty, webhooks, OpsGenie)
- Time-based routing (business hours vs after-hours, maintenance windows)
- Escalation patterns (progressive escalation, multi-tier on-call, follow-the-sun)
- Template customization (defining templates, data structure, advanced examples)

**Key examples:**
- Routing by severity (critical → page, warning → Slack, info → ticket)
- Inhibition rules (database down suppresses API errors)
- Time-based routing (different receivers for business hours vs after-hours)
- Multi-tier on-call escalation
- Custom notification templates for Slack and email

**When to use:** Configuring Alertmanager, reducing alert noise, implementing on-call rotations, customizing notifications

---

## Quick Reference

### Alert Severity Levels

| Severity | Use Case | Notification | Response Time |
|----------|----------|--------------|---------------|
| **critical** | P1 incident, immediate user impact | Page on-call | Immediate |
| **page** | P2 incident, degraded experience | Page during business hours | < 1 hour |
| **warning** | P3 incident, potential issue | Slack notification | Next business day |
| **info** | Informational, trending concern | Jira ticket | As time permits |

### SLO Targets by Service Tier

| Tier | SLO | Downtime/Month | Use Case |
|------|-----|----------------|----------|
| **Critical** | 99.99% | 4.32 minutes | Payment systems, core platform |
| **High** | 99.9% | 43.2 minutes | User-facing services |
| **Standard** | 99% | 7.2 hours | Internal tools, admin interfaces |
| **Low** | 95% | 36 hours | Experimental features, batch jobs |

### Burn Rate Alert Tiers (99.9% SLO)

| Tier | Burn Rate | Windows | Budget Impact | Severity |
|------|-----------|---------|---------------|----------|
| **Page (urgent)** | 14.4x | 1h / 5m | 2% per hour | critical |
| **Page (moderate)** | 6x | 6h / 30m | 5% in 6 hours | warning |
| **Ticket (slow)** | 3x | 1d / 2h | 10% per day | info |
| **Ticket (baseline)** | 1x | 3d / 6h | 100% in 30 days | info |

### Recording Rule Naming Convention

```
sli:http_availability:ratio_5m        # SLI metric
slo:error_rate:5m                     # Error rate
burn_rate:http_availability:1h        # Burn rate
service:http_requests:rate_5m         # Service-level aggregation
cluster:http_availability:ratio_5m    # Cluster-level aggregation
```

### Essential PromQL Patterns

```promql
# Availability
sum(rate(http_requests_total{status!~"5.."}[5m])) by (service)
  /
sum(rate(http_requests_total[5m])) by (service)

# Error rate
sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
  /
sum(rate(http_requests_total[5m])) by (service)

# P99 latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
)

# Burn rate
(error_rate / error_budget)
```

### Essential LogQL Patterns

```logql
# Error rate from logs
sum(rate({app="api"} |= "error" [5m]))
  /
sum(rate({app="api"}[5m]))

# Security pattern detection
count_over_time({app="api"}
  |~ "(password|api_key|token)\\s*[:=]\\s*['\"]?\\w{8,}"
  [5m])

# Structured log parsing
{app="api"} | json | status < 500

# Slow query detection
{app="database"} | json | duration > 5s
```

---

## Implementation Checklist

### Phase 1: Foundation (Week 1)

- [ ] Configure Loki and Mimir rulers
- [ ] Set up Alertmanager (standalone or embedded in Mimir)
- [ ] Define basic recording rules for key services
- [ ] Create severity-based routing in Alertmanager
- [ ] Test end-to-end alert flow (rule → Alertmanager → receiver)

### Phase 2: SLO Definition (Week 2)

- [ ] Identify critical user journeys
- [ ] Define SLIs for each journey (availability, latency)
- [ ] Set initial SLO targets (start at 99%)
- [ ] Implement SLI recording rules (multi-window)
- [ ] Create dashboards showing SLI trends

### Phase 3: Burn Rate Alerts (Week 3)

- [ ] Calculate burn rate thresholds for your SLOs
- [ ] Implement burn rate recording rules
- [ ] Create four-tier burn rate alerts (14.4x, 6x, 3x, 1x)
- [ ] Configure appropriate routing and grouping
- [ ] Test with synthetic error injection

### Phase 4: Refinement (Week 4)

- [ ] Monitor alert precision and recall
- [ ] Adjust thresholds based on false positives
- [ ] Add inhibition rules to prevent cascading alerts
- [ ] Implement time-based routing for business hours
- [ ] Create runbooks for each alert

### Phase 5: Operationalization (Ongoing)

- [ ] Weekly error budget review
- [ ] Monthly alert quality review
- [ ] Quarterly SLO target review
- [ ] Document learnings and patterns
- [ ] Train team on SLO-based incident response

---

## Common Pitfalls to Avoid

### Alert Design

- ❌ **Alert on symptoms, not impact**: "CPU > 80%" instead of "Error rate high"
- ❌ **Too many alerts**: Causes alert fatigue and ignoring
- ❌ **Alerts without runbooks**: On-call engineer doesn't know what to do
- ❌ **No `for` clause on noisy metrics**: Floods with transient alerts
- ❌ **Alert on everything**: Not everything needs immediate attention

### SLO Definition

- ❌ **SLO too high for capabilities**: Causes constant firefighting
- ❌ **SLO based on infrastructure metrics**: Focus on user experience, not CPU
- ❌ **One SLO for different request types**: Group by criticality
- ❌ **No error budget policy**: Engineers unclear when to slow down
- ❌ **Measuring at wrong layer**: Measure as close to user as possible

### Recording Rules

- ❌ **High cardinality in recording rules**: Explodes storage
- ❌ **Inconsistent time windows**: Can't combine for multi-window alerts
- ❌ **No naming convention**: Hard to understand what metrics mean
- ❌ **Overly complex expressions**: Break into layers
- ❌ **Not testing recording rules**: Errors only discovered in production

### Alertmanager Configuration

- ❌ **No grouping**: Each instance sends separate notification
- ❌ **Wrong group_by labels**: Related alerts don't group together
- ❌ **No inhibition rules**: Alert storms during incidents
- ❌ **Same routing for all severities**: Critical alerts get lost in noise
- ❌ **No time-based routing**: Paging at 3am for non-urgent issues

---

## Additional Resources

### Official Documentation

- [Prometheus Alerting Rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
- [Prometheus Recording Rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/)
- [Prometheus Alertmanager](https://prometheus.io/docs/alerting/latest/)
- [Grafana Loki Alerting](https://grafana.com/docs/loki/latest/alert/)
- [Grafana Mimir Ruler](https://grafana.com/docs/mimir/latest/references/architecture/components/ruler/)
- [Grafana Mimir Alertmanager](https://grafana.com/docs/mimir/latest/references/architecture/components/alertmanager/)

### Google SRE Resources

- [Google SRE Book: Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)
- [Google SRE Book: Practical Alerting](https://sre.google/sre-book/practical-alerting/)
- [Google SRE Workbook: Implementing SLOs](https://sre.google/workbook/implementing-slos/)
- [Google SRE Workbook: Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)

### Community Resources

- [SoundCloud: Alerting on SLOs](https://developers.soundcloud.com/blog/alerting-on-slos/)
- [Grafana Blog: Multi-Window Multi-Burn-Rate Alerts](https://grafana.com/blog/2025/02/28/how-to-implement-multi-window-multi-burn-rate-alerts-with-grafana-cloud/)
- [Sloth: Prometheus SLO Generator](https://github.com/slok/sloth)
- [Pyrra: SLO Management Tool](https://github.com/pyrra-dev/pyrra)

### LGTM Stack Configuration

- Loki configuration: `config/loki-config.yaml`
- Mimir configuration: `config/mimir-config.yaml`
- OTel Collector: `config/otel-collector-config.yaml`

---

## Contributing

This documentation is maintained as part of the LGTM local stack project. To update:

1. Research new patterns or improvements
2. Document findings in appropriate section
3. Include concrete examples with PromQL/LogQL
4. Test examples against local stack
5. Update this README if adding new sections

---

## Changelog

**2025-11-28**: Initial documentation creation
- 01-alert-rule-design.md: Complete guide to LogQL and PromQL alert patterns
- 02-slo-sli-patterns.md: SLO/SLI definitions, error budgets, implementation patterns
- 03-multi-burn-rate-alerting.md: Google SRE multi-window multi-burn-rate methodology
- 04-recording-rules.md: Pre-computation patterns for performance and consistency
- 05-notification-routing.md: Alertmanager configuration, routing, escalation
