# Task: demo-service Grafana Dashboards

**Created:** 2025-12-01
**Status:** Completed

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Dashboard separation | Client + Environment | Each client/env operates with different parameters and behaviors |
| Dashboard organization | Flat "demo-service" folder with naming convention | Cleaner than nested folders, easy to find specific dashboards |
| Global overview | Yes | Cross-client comparison and aggregate visibility |
| Initial clients | dev, qa, uat | Representative sample across environments |
| Default time range | 6 hours | Balance between real-time and trend visibility (user-adjustable via picker) |

## Approach

Create client+environment-specific Grafana dashboards plus a global overview to visualize demo-service connector telemetry data from Tempo traces. Dashboards will use TraceQL queries against Tempo and be provisioned via JSON files in the Grafana provisioning directory.

**Naming convention:** `demo-service-{client}-{env}-{dashboard-type}.json`

**Dashboard count:** 13 total
- 3 clients × 4 dashboard types = 12 client-specific dashboards
- 1 global overview dashboard

**File locations:**
- `config/grafana/provisioning/dashboards/demo-service/` - All dashboard JSON files
- `config/grafana/provisioning/dashboards/dashboards.yaml` - Folder provisioning config

## Tasks

1. Create folder structure for demo-service dashboards
   - Create `config/grafana/provisioning/dashboards/demo-service/` directory
   - Update `dashboards.yaml` for demo-service folder provisioning

2. Create Global Overview dashboard (`demo-service-global-overview.json`)
   - **Row 1: Cross-Client Health**
     - Request rate by client/environment (time series, stacked)
     - Error rate by client/environment
     - Current error counts per client (stat panels or table)
   - **Row 2: Latency Comparison**
     - p95 latency by client/environment (time series)
     - Latency comparison table (p50, p95, p99 per client)
   - **Row 3: Volume Distribution**
     - Request volume breakdown (bar chart by client/env)
     - Document type distribution across clients

3. Create Operations Overview dashboards (per client/env)
   - Files: `demo-service-dev-operations-overview.json`, `demo-service-qa-operations-overview.json`, `demo-service-uat-operations-overview.json`
   - **Row 1: Health Indicators**
     - Request rate (traces over time)
     - Error rate percentage
     - Current error count (stat panel)
   - **Row 2: Latency**
     - Latency percentiles (p50, p95, p99) - time series
     - Latency heatmap
   - **Row 3: Breakdown**
     - Top endpoints by volume (bar chart)
     - Operation status distribution (pie chart: success/not_found/partial_success)
     - HTTP status code distribution

4. Create Document Processing dashboards (per client/env)
   - Files: `demo-service-dev-document-processing.json`, `demo-service-qa-document-processing.json`, `demo-service-uat-document-processing.json`
   - **Row 1: Document Volume**
     - Documents by type over time (`context.documentType`)
     - Current document type distribution (pie)
   - **Row 2: Performance by Type**
     - Processing time by document type (bar chart)
     - Slowest document types (table)
   - **Row 3: Operations**
     - Batch size distribution histogram (`db.record_count`)
     - Query vs Command ratio (stat panels)
     - Result count trends (`operation.result_count`)

5. Create Database Operations dashboards (per client/env)
   - Files: `demo-service-dev-database-operations.json`, `demo-service-qa-database-operations.json`, `demo-service-uat-database-operations.json`
   - **Row 1: Collection Activity**
     - Operations by collection over time (`db.collection.name`)
     - Top models by call volume (bar chart)
   - **Row 2: Query Patterns**
     - Pagination analysis - take/skip value distributions
     - Query complexity breakdown (has_where, has_orderby usage)
   - **Row 3: Batch Operations**
     - Batch sizes over time
     - Cursor pagination usage rate

6. Create Client/Group Performance dashboards (per client/env)
   - Files: `demo-service-dev-group-performance.json`, `demo-service-qa-group-performance.json`, `demo-service-uat-group-performance.json`
   - **Row 1: Volume Distribution**
     - Request volume by group (`context.groups`)
     - Volume by application header (`x-application`)
   - **Row 2: Performance**
     - Latency by group
     - Error rate by group
   - **Row 3: Workload Profile**
     - Document types per group (heatmap or table)
     - Operations breakdown per group

7. Verify docker-compose mounts dashboard provisioning directory correctly

8. Test dashboards with sample trace data
   - Start LGTM stack
   - Send test traces via OTLP
   - Verify all panels render correctly

9. Review implementation and capture key facts/learnings to memory (with user review)

## Technical Notes

### Data Sources
- **Tempo**: Trace data with span attributes
- Datasource UID in provisioned config: `tempo`

### Key Span Attributes Available

```
# Controller layer
controller.name, controller.method
context.documentType, context.groups, context.appName
http.request.method, http.route, url.full
http.status_code

# Service/DB layer
db.operation, db.collection.name, db.unique_field
db.query.limit, db.query.offset, db.query.has_where, db.query.has_orderby
db.record_count, db.query.cursor
operation.status, operation.result_count, operation.records_affected

# Document layer
doc.idmpKey, doc.lineNo, doc.itemId, doc.code
```

### TraceQL Query Examples by Panel Type

**Request Rate (time series):**
```traceql
{resource.service.name="demo-service"} | rate()
```

**Error Rate:**
```traceql
{resource.service.name="demo-service" && status=error} | rate()
```

**Latency Percentiles:**
```traceql
{resource.service.name="demo-service"} | quantile_over_time(duration, 0.5, 0.95, 0.99)
```

**Group by Attribute (e.g., endpoint):**
```traceql
{resource.service.name="demo-service"} | rate() by(http.route)
```

**Filter by Document Type:**
```traceql
{resource.service.name="demo-service" && span.context.documentType="purchaseOrder"}
```

**Database Operations by Model:**
```traceql
{resource.service.name="demo-service" && span.db.collection.name != ""} | rate() by(span.db.collection.name)
```

**Operation Status Distribution:**
```traceql
{resource.service.name="demo-service"} | count() by(span.operation.status)
```

### Grafana Dashboard JSON Structure

```json
{
  "uid": "demo-service-operations-overview",
  "title": "demo-service Operations Overview",
  "tags": ["demo-service"],
  "timezone": "browser",
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "refresh": "30s",
  "panels": [...]
}
```

### Panel Types to Use

| Visualization | Use Case |
|---------------|----------|
| Time series | Rate over time, latency trends |
| Stat | Current values (error count, request rate) |
| Bar chart | Top N breakdowns |
| Pie chart | Distribution (status codes, operation types) |
| Heatmap | Latency distribution over time |
| Table | Detailed breakdowns with multiple columns |

### Folder Provisioning

To create the "demo-service" folder, add to `dashboards.yaml`:
```yaml
providers:
  - name: 'demo-service'
    orgId: 1
    folder: 'demo-service'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards/demo-service
```

### Service Name Reference

The demo-service connector uses `resource.service.name` with the pattern: `{client}/{environment}/{component}`

**Service names for initial scope:**
- `tenant-a/dev/demo-service`
- `tenant-a/qa/demo-service`
- `tenant-b/uat/demo-service`

**Global overview filter (all demo-service instances):**
```traceql
{resource.service.name =~ ".*demo-service"}
```

### Future Metrics Consideration

When trace-based queries become expensive or alerting is needed, implement these metrics:

```
# Counters
demo_service_requests_total{controller, method, doc_type, status}
demo_service_documents_processed_total{doc_type, operation}
demo_service_db_operations_total{model, operation}

# Histograms
demo_service_request_duration_seconds{controller, method, doc_type}
demo_service_db_query_duration_seconds{model, operation}
demo_service_batch_size{operation}
```

Trigger for metrics implementation:
- Dashboard query latency > 5s
- Need for real-time alerting (< 1 min detection)
- SLO/SLI tracking requirements
