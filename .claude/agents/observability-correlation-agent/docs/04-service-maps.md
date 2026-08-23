# Service Maps and Service Graph Visualization

## Overview

Service maps (also called service graphs) provide a visual representation of the relationships between services in a distributed system. They show which services call which other services, along with request rates, error rates, and latency metrics. This topology view is crucial for understanding system architecture, identifying bottlenecks, and troubleshooting distributed issues.

## How Service Graphs Work

Tempo's metrics-generator analyzes traces to identify **edges** - spans with parent-child relationships that represent service-to-service communication:

```
Client Service (parent span)
    ↓ (edge detected)
Server Service (child span)
```

For each edge, metrics are generated:
- **Request count**: Total requests between services
- **Error count**: Failed requests
- **Duration**: Latency of requests (client and server perspective)

These metrics are exported to Prometheus/Mimir and visualized in Grafana.

## Architecture

```
Application Traces → Tempo → Metrics Generator → Mimir/Prometheus
                                    ↓
                              Service Graph Metrics
                                    ↓
                          Grafana Service Graph View
```

## Current Configuration

### Tempo Metrics Generator

Located in: `config/tempo-config.yaml`

```yaml
metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /tmp/tempo/generator/wal
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true
```

**To enable service graphs**, add processor configuration:

```yaml
metrics_generator:
  # ... existing config ...
  processor:
    service_graphs:
      # Dimensions to include in service graph metrics
      dimensions:
        - service.name
        - service.namespace
        - deployment.environment

      # Histogram buckets for latency (in seconds)
      histogram_buckets: [0.1, 0.25, 0.5, 1, 2.5, 5, 10]

      # Wait time before flushing service graph metrics
      wait: 10s

      # Maximum items in each queue before eviction
      max_items: 10000

      # Workers processing the queues
      workers: 10
```

### Grafana Datasource Configuration

Located in: `config/grafana/provisioning/datasources/datasources.yaml`

```yaml
- name: Tempo
  type: tempo
  uid: tempo
  access: proxy
  url: http://tempo:3200
  jsonData:
    httpMethod: GET
    serviceMap:
      datasourceUid: Mimir-Prometheus  # Link to metrics datasource
    # ... other config ...
```

**Key Configuration:**
- `serviceMap.datasourceUid`: Points to Prometheus/Mimir datasource containing service graph metrics

## Service Graph Metrics

When service graphs are enabled, Tempo generates these Prometheus metrics:

### Request Metrics

**traces_service_graph_request_total**

Counter of requests between services.

**Labels:**
- `client`: Source service name
- `server`: Destination service name
- `connection_type`: Optional connection type
- Plus any custom dimensions configured

**Example:**
```promql
traces_service_graph_request_total{
  client="order-service",
  server="payment-service",
  deployment_environment="production"
}
```

### Error Metrics

**traces_service_graph_request_failed_total**

Counter of failed requests between services.

**Labels:** Same as request_total

**Example:**
```promql
traces_service_graph_request_failed_total{
  client="order-service",
  server="payment-service"
}
```

### Latency Metrics

**traces_service_graph_request_server_seconds**

Histogram of request duration from server perspective.

**Buckets:** Configured via `histogram_buckets`

**Example:**
```promql
traces_service_graph_request_server_seconds_bucket{
  client="order-service",
  server="payment-service",
  le="0.5"
} 42
```

**traces_service_graph_request_client_seconds**

Histogram of request duration from client perspective (includes network latency).

### Virtual Node Metrics

For external dependencies (databases, caches, queues):

**traces_service_graph_request_virtual_node_total**

Requests to external systems.

**Labels:**
- `client`: Service making the request
- `server`: Virtual node name (e.g., `postgresql`, `redis`)

## Enabling Service Graphs

### Step 1: Configure Tempo

Edit `config/tempo-config.yaml`:

```yaml
metrics_generator:
  registry:
    external_labels:
      source: tempo
      cluster: local-dev
  storage:
    path: /tmp/tempo/generator/wal
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true

  # Add this section
  processor:
    service_graphs:
      # Core dimensions for service identification
      dimensions:
        - service.name
        - service.namespace
        - deployment.environment

      # Latency buckets (adjust to your SLOs)
      histogram_buckets: [0.002, 0.004, 0.008, 0.016, 0.032, 0.064, 0.128, 0.256, 0.512, 1, 2, 4, 8, 16]

      # Optional: Configure virtual nodes for databases
      peer_attributes:
        - peer.service
        - db.name
        - db.system

      # Enable virtual node label
      enable_virtual_node_label: true
```

### Step 2: Restart Tempo

```bash
cd /path/to/lgtm-stack-experiment
docker compose restart tempo

# Watch logs for service graph processor startup
docker compose logs -f tempo | grep "service_graphs"
```

### Step 3: Verify Metrics in Mimir

Wait 30-60 seconds for metrics to be generated, then query:

```bash
# Check for service graph metrics
curl -s 'http://localhost:9009/api/v1/query?query=traces_service_graph_request_total' | jq '.data.result'

# Check for service graph latency metrics
curl -s 'http://localhost:9009/api/v1/query?query=traces_service_graph_request_server_seconds_count' | jq '.data.result'
```

**Expected output:**
```json
{
  "metric": {
    "__name__": "traces_service_graph_request_total",
    "client": "my-service",
    "server": "downstream-service",
    "deployment_environment": "production",
    "source": "tempo"
  },
  "value": [1732800000, "42"]
}
```

### Step 4: View in Grafana

1. Open Grafana: http://localhost:3000
2. Navigate to **Explore**
3. Select **Tempo** datasource
4. Click **Service Graph** tab
5. Service map should appear showing service relationships

**Alternative: Search for a trace**
1. In Tempo Explore, search for traces
2. Click on a trace
3. Look for **Service Graph** button in trace view
4. Click to see services involved in that trace

## Understanding the Service Graph Visualization

### Node Representation

Each **node** represents a service:
- **Size**: Proportional to request volume
- **Color**: Indicates error rate (green = healthy, red = errors)
- **Label**: Service name

### Edge Representation

Each **edge** represents service-to-service communication:
- **Width**: Proportional to request rate
- **Color**: Indicates health (green = low errors, red = high errors)
- **Label**: Request rate and error rate

### Statistics Panels

Below the graph, Grafana shows tables with:

**Services:**
- Service name
- Request rate (requests/sec)
- Error rate (%)
- P50, P90, P99 latency

**Edges:**
- Client → Server relationship
- Request rate
- Error rate
- Latency percentiles

### Clicking Through

- **Click a node**: Filters graph to show only that service's connections
- **Click an edge**: Shows metrics for that specific service-to-service communication
- **Click trace icon**: Jumps to example traces for that edge

## Best Practices

### 1. Configure Appropriate Dimensions

Balance between granularity and cardinality:

**Recommended dimensions:**
```yaml
dimensions:
  - service.name          # Essential
  - service.namespace     # Groups related services
  - deployment.environment # Separate prod/staging
```

**Avoid high-cardinality dimensions:**
```yaml
# ❌ Don't include these
dimensions:
  - service.instance.id   # Unique per instance
  - http.target          # Unique per endpoint
  - user.id              # Unique per user
```

### 2. Use Virtual Nodes for External Dependencies

Configure peer attributes to identify external systems:

```yaml
service_graphs:
  peer_attributes:
    - peer.service      # Explicit peer service name
    - db.name           # Database name
    - db.system         # Database type (postgresql, mongodb, etc.)
    - messaging.system  # Message broker (kafka, rabbitmq, etc.)
  enable_virtual_node_label: true
```

**Result:** Graph shows connections to databases and queues as distinct nodes.

### 3. Tune Histogram Buckets for Your SLOs

Match buckets to your latency requirements:

**For fast APIs (< 1 second):**
```yaml
histogram_buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1]
```

**For slower operations (seconds to minutes):**
```yaml
histogram_buckets: [0.1, 0.5, 1, 5, 10, 30, 60, 120, 300]
```

**For mixed workloads:**
```yaml
histogram_buckets: [0.002, 0.004, 0.008, 0.016, 0.032, 0.064, 0.128, 0.256, 0.512, 1, 2, 4, 8, 16]
```

### 4. Monitor Metrics Generator Resource Usage

Service graph processing adds overhead:

```bash
# Check memory usage
docker stats tempo --no-stream

# Check WAL size
docker exec tempo du -sh /tmp/tempo/generator/wal

# Check remote write lag
docker compose logs tempo | grep "remote_write"
```

### 5. Set Appropriate Wait Time

The `wait` parameter controls when edges are flushed:

```yaml
service_graphs:
  wait: 10s  # Wait 10 seconds to match parent/child spans
```

**Tradeoffs:**
- **Lower wait time** (e.g., 5s): Faster metric updates, may miss some edges
- **Higher wait time** (e.g., 30s): More accurate edge detection, delayed metrics

### 6. Limit Queue Sizes for High Traffic

Prevent memory issues with max_items:

```yaml
service_graphs:
  max_items: 10000    # Maximum spans in queue
  workers: 10         # Parallel workers processing spans
```

**For high-traffic systems**, increase workers and max_items proportionally.

## Custom Service Graph Queries

### Request Rate Between Services

```promql
# Total requests per second
rate(traces_service_graph_request_total{
  client="order-service",
  server="payment-service"
}[5m])
```

### Error Rate Between Services

```promql
# Error percentage
(
  rate(traces_service_graph_request_failed_total{
    client="order-service",
    server="payment-service"
  }[5m])
  /
  rate(traces_service_graph_request_total{
    client="order-service",
    server="payment-service"
  }[5m])
) * 100
```

### Latency Percentiles

```promql
# P95 latency (server-side)
histogram_quantile(0.95,
  sum by (le, client, server) (
    rate(traces_service_graph_request_server_seconds_bucket{
      client="order-service",
      server="payment-service"
    }[5m])
  )
)
```

### Top Slowest Service Connections

```promql
# Top 10 slowest edges by P99 latency
topk(10,
  histogram_quantile(0.99,
    sum by (le, client, server) (
      rate(traces_service_graph_request_server_seconds_bucket[5m])
    )
  )
)
```

### Service Dependency Fan-out

```promql
# Number of downstream services per client
count by (client) (
  sum by (client, server) (
    rate(traces_service_graph_request_total[5m])
  )
)
```

### External Dependency Requests

```promql
# Requests to databases and external services
rate(traces_service_graph_request_virtual_node_total{
  server=~"postgresql|redis|mongodb"
}[5m])
```

## Grafana Dashboard Example

Create a custom dashboard for service graphs:

### Panel 1: Service Graph Visualization

**Query:**
```promql
traces_service_graph_request_total
```

**Visualization:** Node Graph

**Configuration:**
- **Source field**: client
- **Target field**: server
- **Main stat**: rate (requests/sec)
- **Secondary stat**: error rate (%)

### Panel 2: Request Rate by Service

**Query:**
```promql
sum by (server) (
  rate(traces_service_graph_request_total[5m])
)
```

**Visualization:** Bar Chart

### Panel 3: Error Rate Heatmap

**Query:**
```promql
(
  rate(traces_service_graph_request_failed_total[5m])
  /
  rate(traces_service_graph_request_total[5m])
) * 100
```

**Visualization:** Heatmap (x=time, y=service pairs, color=error rate)

### Panel 4: Latency Distribution

**Query:**
```promql
histogram_quantile(0.50,
  sum by (le, client, server) (
    rate(traces_service_graph_request_server_seconds_bucket[5m])
  )
)
```

**Visualization:** Time Series (P50, P90, P99 as separate queries)

## Troubleshooting

### No Service Graph Data

**Possible causes:**

1. **Service graphs processor not enabled**
   - Check Tempo config for `processor.service_graphs` section
   - Verify Tempo logs show processor startup

2. **No traces being ingested**
   - Verify applications are sending traces to Tempo
   - Check Tempo ingestion metrics

3. **Metrics not reaching Mimir**
   - Check Tempo logs for remote write errors
   - Verify Mimir is accepting writes
   - Check network connectivity between Tempo and Mimir

4. **Wrong datasource UID**
   - Verify `serviceMap.datasourceUid` in Tempo datasource config
   - Ensure it matches Mimir-Prometheus datasource UID

### Service Graph Shows Incomplete Topology

**Possible causes:**

1. **Wait time too short**
   - Parent and child spans not matched within `wait` period
   - Increase `wait` parameter (e.g., from 10s to 30s)

2. **Missing parent spans**
   - Some services not instrumented
   - Verify all services have OpenTelemetry instrumentation

3. **Context propagation broken**
   - Trace context not passed between services
   - Check HTTP headers or message attributes for trace context

### High Cardinality Issues

**Symptoms:**
- Tempo using excessive memory
- Metrics queries slow in Grafana
- Large number of unique metric series

**Solutions:**

1. **Reduce dimensions**:
   ```yaml
   dimensions:
     - service.name  # Keep only essential dimensions
   ```

2. **Filter spans**:
   ```yaml
   service_graphs:
     filter_policies:
       - include:
           match_type: strict
           attributes:
             - key: span.kind
               value: SPAN_KIND_SERVER  # Only process server spans
   ```

3. **Aggregate by namespace**:
   ```yaml
   dimensions:
     - service.namespace  # Use namespace instead of individual services
   ```

## Integration with @your-org/instrumentation

Service graphs work automatically with the instrumentation library:

```javascript
import {initOtelInstrumentation} from '@your-org/instrumentation';

// This is all you need - service graphs generated from traces
initOtelInstrumentation({
    componentName: 'order-service'
});

// Service graphs will show:
// - order-service as the client node
// - Downstream HTTP calls as edges to server nodes
// - Database calls as edges to virtual nodes
```

**Environment variables for context:**
```bash
export OTEL_SERVICE_NAME=order-service
export AP_ENVIRONMENT=production

# Optional: For multi-namespace deployments
export OTEL_RESOURCE_ATTRIBUTES="service.namespace=ecommerce"
```

## Advanced Configuration

### Custom Service Names for Virtual Nodes

Override peer service detection:

```yaml
service_graphs:
  peer_attributes:
    - peer.service         # Highest priority
    - db.name              # Used if peer.service absent
    - db.system            # Used if db.name absent
    - messaging.destination # For message queues
```

**Priority order**: First attribute found is used as the peer (server) name.

### Multi-Tenant Service Graphs

For multi-tenant deployments:

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true
        headers:
          X-Scope-OrgID: ${TENANT_ID}

  processor:
    service_graphs:
      dimensions:
        - tenant.id        # Separate graphs by tenant
        - service.name
```

### Custom Graph Layouts

In Grafana, customize the node graph visualization:

- **Layout algorithm**: Force-directed, hierarchical, circular
- **Node sizing**: By request rate, error rate, or custom metric
- **Edge thickness**: By request volume or latency
- **Color schemes**: Red/yellow/green for health, or custom gradients

## Reference Links

- **Tempo Service Graphs**: https://grafana.com/docs/tempo/latest/metrics-generator/service_graphs/
- **Grafana Node Graph Panel**: https://grafana.com/docs/grafana/latest/panels/visualizations/node-graph/
- **Service Graph View**: https://grafana.com/docs/grafana/latest/datasources/tempo/service-graph/
- **Metrics Generator Config**: https://grafana.com/docs/tempo/latest/configuration/#metrics-generator
