# Grafana Visualization Agent Documentation

**Purpose**: Comprehensive reference documentation for the grafana-visualization-agent to provide expert guidance on Grafana configuration, dashboards, visualizations, and alerting in the LGTM stack.

**Created**: 2025-11-28
**Last Updated**: 2025-11-28

---

## Overview

This documentation provides detailed, actionable guidance for configuring and optimizing Grafana in the LGTM (Loki, Grafana, Tempo, Mimir) observability stack. It covers all aspects of Grafana configuration from datasources to alerting.

---

## Documentation Structure

### [01-datasource-configuration.md](./01-datasource-configuration.md)

**Comprehensive datasource setup and cross-datasource linking**

Topics covered:
- Loki datasource configuration
- Derived fields for linking logs to traces
- Tempo datasource with tracesToLogs and tracesToMetrics
- Service graph and trace search configuration
- Prometheus/Mimir datasource with exemplars
- Cross-datasource linking patterns (LGTM integration)
- YAML provisioning examples
- Troubleshooting datasource issues

**Key Patterns**:
- Logs → Traces (Loki derived fields)
- Traces → Logs (Tempo tracesToLogs)
- Traces → Metrics (Tempo tracesToMetrics)
- Metrics → Traces (Mimir/Prometheus exemplars)

**Current Project Reference**: `config/grafana/provisioning/datasources/datasources.yaml`

---

### [02-dashboard-provisioning.md](./02-dashboard-provisioning.md)

**Dashboard JSON structure, provisioning, and GitOps management**

Topics covered:
- Dashboard provisioning configuration (provider YAML)
- Dashboard JSON structure and key fields
- Panel configuration and grid layout system
- Template variables (query, custom, constant, datasource)
- Annotations for event tracking
- Rows and dashboard organization
- Export/import workflow
- Dashboard linking patterns
- Common dashboard patterns (RED metrics, LGTM health)

**Key Concepts**:
- 24-column grid layout system
- UID-based dashboard updates
- Variable usage in queries and titles
- Hot reload vs. full restart
- Folder organization strategies

**Best Practices**:
- Always use UIDs for versioned dashboards
- Remove dynamic fields before provisioning
- Use meaningful file names
- Organize with folder structures
- Document dashboard purpose

---

### [03-visualization-patterns.md](./03-visualization-patterns.md)

**Panel types, observability methodologies, and design best practices**

Topics covered:
- Panel types for observability:
  - Time series (metrics)
  - Stat panels (KPIs)
  - Gauge and bar gauge
  - Logs panel
  - Traces panel
  - Node graph (service map)
  - Table and heatmap
- Observability dashboard patterns:
  - RED Method (Rate, Errors, Duration)
  - USE Method (Utilization, Saturation, Errors)
  - Four Golden Signals
  - Multi-service comparison
  - LGTM stack health monitoring
- Color and threshold strategies
- Layout best practices
- Variable patterns
- Dashboard maturity model

**Key Methodologies**:

**RED Method** (microservices):
- Rate: Requests per second
- Errors: Failed requests
- Duration: Request latency (P50, P95, P99)

**USE Method** (infrastructure):
- Utilization: Resource busy time (CPU, memory)
- Saturation: Queue depth (load average)
- Errors: Error events

**Design Principles**:
- Blue = good, Red = bad (consistent colors)
- Top-to-bottom information hierarchy
- Left-to-right data flow
- Consistent panel sizing
- Meaningful thresholds based on SLOs

---

### [04-alerting-configuration.md](./04-alerting-configuration.md)

**Grafana unified alerting, provisioning, and notification routing**

Topics covered:
- Grafana unified alerting architecture
- Alert rule provisioning (YAML)
- Query types: metrics, reduce, threshold
- Alert rule examples:
  - High error rate (Prometheus)
  - High latency (histogram quantiles)
  - Error logs (Loki)
  - Slow traces (Tempo/TraceQL)
  - LGTM component health
- Contact points (email, Slack, PagerDuty, webhook, etc.)
- Notification policies and routing
- Object matchers for label-based routing
- Mute timings for scheduled silences
- Message templates
- Testing and troubleshooting

**Key Concepts**:
- Alert rule evaluation cycle
- Multi-stage queries (metric → reduce → threshold)
- Label-based routing with notification policies
- Group by, group wait, repeat interval
- continue flag for multi-destination routing

**Best Practices**:
- Alert on symptoms, not causes
- Set appropriate "for" duration to avoid flapping
- Use meaningful labels for routing
- Write actionable annotations with runbook URLs
- Implement routing hierarchy (critical → warning → info)
- Group related alerts to reduce noise

---

## Quick Reference

### Current LGTM Stack Configuration

**Datasources** (configured):
- Loki: `http://loki:3100` (UID: `Loki`)
- Tempo: `http://tempo:3200` (UID: `tempo`)
- Mimir-Prometheus: `http://mimir:9009` (UID: `Mimir-Prometheus`)

**Cross-datasource linking** (active):
- Loki → Tempo: Derived field `traceID=(\w+)`
- Tempo → Loki: tracesToLogs with tags `[job, instance, pod, namespace]`
- Tempo → Mimir: Service map enabled
- Mimir → Tempo: Exemplars `trace_id` to Tempo

**Access**:
- Grafana UI: http://localhost:3000
- Default credentials: admin/admin

---

## Use Cases by Document

### "I need to configure a new datasource"
→ **01-datasource-configuration.md**
Section: "Datasource Provisioning Basics"

### "I want to link logs to traces"
→ **01-datasource-configuration.md**
Section: "Derived Fields - Linking Logs to Traces"

### "I need to create a service dashboard"
→ **02-dashboard-provisioning.md** + **03-visualization-patterns.md**
Sections: "Dashboard JSON Structure" + "RED Method Dashboard"

### "I want to add variables to my dashboard"
→ **02-dashboard-provisioning.md**
Section: "Template Variables"

### "I need to visualize metrics over time"
→ **03-visualization-patterns.md**
Section: "Time Series (Primary Metric Visualization)"

### "I want to create alerts for high error rates"
→ **04-alerting-configuration.md**
Section: "High Error Rate (Prometheus)"

### "I need to route critical alerts to PagerDuty"
→ **04-alerting-configuration.md**
Section: "Notification Policies (Routing)"

---

## Integration Examples

### Complete Observability Flow

```
1. Application emits telemetry (OpenTelemetry)
   ↓
2. OTel Collector receives OTLP data
   ↓
3. Data distributed to backends:
   - Logs → Loki
   - Traces → Tempo
   - Metrics → Mimir
   ↓
4. Grafana queries all three datasources
   ↓
5. Cross-datasource linking enables:
   - Click trace ID in log → View trace in Tempo
   - Click "View Logs" in trace → See related logs in Loki
   - Click exemplar on graph → Jump to trace
   ↓
6. Alerts evaluate queries and send notifications
```

### Example Dashboard Structure

```
Service RED Metrics Dashboard
├── Variables: $datasource, $service, $environment
├── Row: Overview
│   ├── Stat: Request Rate (current)
│   ├── Stat: Error Rate (with thresholds)
│   └── Stat: P95 Latency (with unit: ms)
├── Row: Request Metrics
│   ├── Time Series: Request Rate Over Time (by status)
│   └── Time Series: Request Rate by Endpoint
├── Row: Error Analysis
│   ├── Time Series: Error Rate Percentage
│   ├── Logs: Recent Errors (with trace links)
│   └── Table: Error Summary by Endpoint
├── Row: Latency Analysis
│   ├── Time Series: Latency Percentiles (P50, P95, P99)
│   └── Heatmap: Request Duration Distribution
└── Row: Distributed Tracing
    ├── Traces: Slow Traces (duration > 1s)
    └── Node Graph: Service Dependencies
```

---

## Common Patterns and Solutions

### Pattern: Logs → Traces → Metrics Correlation

**Problem**: Need to correlate logs, traces, and metrics for a single request

**Solution**:

1. **Configure derived fields** (Loki → Tempo):
   ```yaml
   derivedFields:
     - datasourceUid: tempo
       matcherRegex: traceID=(\w+)
       name: TraceID
       url: $${__value.raw}
   ```

2. **Configure tracesToLogs** (Tempo → Loki):
   ```yaml
   tracesToLogs:
     datasourceUid: Loki
     tags: ['job', 'instance']
     filterByTraceID: true
   ```

3. **Configure exemplars** (Mimir → Tempo):
   ```yaml
   exemplarTraceIdDestinations:
     - name: trace_id
       datasourceUid: tempo
   ```

**Result**: Click through logs → traces → metrics seamlessly

---

### Pattern: Multi-Service RED Dashboard

**Problem**: Need one dashboard for all microservices

**Solution**:

1. **Add service variable**:
   ```json
   {
     "name": "service",
     "type": "query",
     "query": "label_values(http_requests_total, service)",
     "multi": true,
     "includeAll": true
   }
   ```

2. **Use variable in queries**:
   ```promql
   sum(rate(http_requests_total{service=~"$service"}[5m])) by (service)
   ```

3. **Group by service** in all panels

**Result**: Single dashboard adapts to any service selection

---

### Pattern: Alert Routing by Severity

**Problem**: Route alerts to different channels based on severity

**Solution**:

1. **Label alerts with severity**:
   ```yaml
   labels:
     severity: critical  # or warning, info
   ```

2. **Configure notification policies**:
   ```yaml
   routes:
     - receiver: pagerduty-critical
       object_matchers:
         - ['severity', '=', 'critical']
     - receiver: slack-alerts
       object_matchers:
         - ['severity', '=', 'warning']
     - receiver: email-ops
       object_matchers:
         - ['severity', '=', 'info']
   ```

**Result**: Critical → PagerDuty, Warning → Slack, Info → Email

---

## Troubleshooting Guide

### Issue: Datasource not connecting

**Check**:
1. URL is correct and service is accessible
2. Grafana container can reach backend (network)
3. Backend service is healthy: `docker compose ps`
4. Logs: `docker compose logs grafana | grep -i datasource`

**Solution**: Verify network connectivity and service URLs

---

### Issue: Derived fields not showing

**Check**:
1. Regex pattern matches log format exactly
2. Logs contain the expected pattern
3. `datasourceUid` matches target datasource UID
4. Grafana datasources reloaded

**Test**: Use https://regex101.com/ with sample log line

---

### Issue: Dashboard not appearing after provisioning

**Check**:
1. JSON is valid: `jq . dashboard.json`
2. File in correct directory
3. UID doesn't conflict with existing dashboard
4. Grafana logs: `docker compose logs grafana`

**Solution**: Validate JSON, check logs, restart Grafana

---

### Issue: Alerts not firing

**Check**:
1. Alert rule evaluation state (Grafana UI)
2. Query returns data in Explore
3. Condition threshold is met
4. `for` duration has elapsed
5. Alert not muted

**Debug**: Test query in Explore, check evaluation state

---

## External Resources

### Official Grafana Documentation
- Main docs: https://grafana.com/docs/grafana/latest/
- Datasources: https://grafana.com/docs/grafana/latest/datasources/
- Dashboards: https://grafana.com/docs/grafana/latest/dashboards/
- Alerting: https://grafana.com/docs/grafana/latest/alerting/
- Provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/

### LGTM Stack Documentation
- Loki: https://grafana.com/docs/loki/latest/
- Tempo: https://grafana.com/docs/tempo/latest/
- Mimir: https://grafana.com/docs/mimir/latest/
- OpenTelemetry: https://opentelemetry.io/docs/

### Community Resources
- Dashboard library: https://grafana.com/grafana/dashboards/
- Community forums: https://community.grafana.com/
- GitHub examples: https://github.com/grafana/provisioning-alerting-examples

### Observability Methodologies
- RED Method: https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/
- USE Method: http://www.brendangregg.com/usemethod.html
- Google SRE Book: https://sre.google/sre-book/monitoring-distributed-systems/

---

## Contributing to Documentation

When updating these docs:

1. **Keep examples practical** - Use real-world scenarios from LGTM stack
2. **Include YAML/JSON snippets** - Show complete, working configurations
3. **Reference current project** - Point to actual files in the repository
4. **Test configurations** - Verify examples work before documenting
5. **Update "Last Updated" date** - Track documentation freshness

---

## Agent Usage Notes

When the grafana-visualization-agent is invoked:

1. **Start with these docs** - Read relevant sections based on user's question
2. **Provide specific examples** - Use snippets from documentation
3. **Reference current config** - Check actual provisioning files in project
4. **Suggest improvements** - Recommend optimizations based on best practices
5. **Explain trade-offs** - Help user understand implications of choices

**Documentation covers**:
- ✅ Datasource configuration and linking
- ✅ Dashboard provisioning and JSON structure
- ✅ Panel types and visualization patterns
- ✅ Observability methodologies (RED, USE)
- ✅ Alerting configuration and routing
- ✅ Best practices and troubleshooting

**Not covered** (out of scope):
- ❌ Loki query language (LogQL) deep dive
- ❌ Tempo TraceQL advanced syntax
- ❌ PromQL optimization (basic examples only)
- ❌ Grafana plugin development
- ❌ Backend configuration (Loki/Tempo/Mimir internals)

For backend-specific questions, refer users to:
- **lgtm-backends-config-agent** - Loki, Tempo, Mimir configuration
- **otel-collector-architecture-agent** - OTel Collector pipeline optimization

---

## Quick Command Reference

```bash
# Validate dashboard JSON
jq . dashboard.json

# Test Grafana datasource connection
curl http://localhost:3000/api/datasources/proxy/1/api/v1/query \
  -u admin:admin \
  --data-urlencode 'query=up'

# View Grafana logs
docker compose logs -f grafana

# Reload provisioning (hot reload)
# Changes detected automatically every 30s

# Full restart
docker compose restart grafana

# Check datasource health
docker compose ps loki tempo mimir

# Access Grafana
open http://localhost:3000
```

---

## Document Maintenance

**Review Schedule**: Quarterly or when Grafana version changes

**Last Grafana Version Tested**: Grafana 11.x (latest as of 2025-11-28)

**Next Review**: 2026-02-28

---

## Summary

This documentation provides a complete reference for configuring and optimizing Grafana in the LGTM observability stack. It covers:

1. **Datasource Configuration** - Set up and link Loki, Tempo, and Mimir
2. **Dashboard Provisioning** - Create version-controlled dashboards
3. **Visualization Patterns** - Design effective observability dashboards
4. **Alerting Configuration** - Implement comprehensive alerting

Use these docs to build production-ready observability dashboards with best practices from day one.
