# OpenTelemetry Semantic Conventions

## Overview

Semantic conventions define standard attribute names and values for telemetry data. Following these conventions ensures that traces, metrics, and logs can be correlated across services, languages, and vendors. They provide a common vocabulary for describing operations, resources, and telemetry context.

**Why They Matter:**
- Enable cross-signal correlation (traces → logs → metrics)
- Allow generic tooling to understand telemetry data
- Facilitate vendor-neutral observability
- Support automatic dashboards and alerts

## Core Concepts

### Resource Attributes

Resource attributes describe the entity producing telemetry (the service, container, host, etc.). These are **static** for the lifetime of a process.

### Span Attributes

Span attributes describe individual operations. These are **dynamic** and vary per request.

### Semantic Attribute Stability

OpenTelemetry semantic conventions have stability levels:

- **Stable**: Production-ready, won't change without major version bump
- **Experimental**: May change in future versions
- **Deprecated**: Being phased out, use alternatives

**Current Status (as of 2024):** HTTP conventions are transitioning from experimental to stable. Use `OTEL_SEMCONV_STABILITY_OPT_IN=http` environment variable for new stable conventions.

## Required Resource Attributes

### service.name (REQUIRED)

The logical name of the service.

**Type**: `string`

**Example**: `order-service`, `user-api`, `payment-processor`

**Requirements:**
- MUST be the same for all instances of horizontally scaled services
- MUST be unique within a namespace (or globally if no namespace)
- If not specified, SDK defaults to `unknown_service:<process.executable.name>`

**With @your-org/instrumentation:**

```javascript
import {initOtelInstrumentation} from '@your-org/instrumentation';

initOtelInstrumentation({
    componentName: 'order-service'  // Sets service.name
});
```

**Environment variable fallback:**
```bash
export OTEL_SERVICE_NAME=order-service
```

### service.instance.id (RECOMMENDED)

Unique identifier for the service instance.

**Type**: `string`

**Example**: `627cc493-f310-47de-96bd-71410b7dec09`

**Requirements:**
- MUST be unique for each instance of the same `service.namespace`/`service.name` pair
- Should be stable across restarts (but not required)
- Recommended: Use UUID v4 for ephemeral instances, UUID v5 for stable instances

**Kubernetes example:**
```javascript
{
  'service.instance.id': process.env.HOSTNAME,  // Pod name
  'k8s.pod.uid': process.env.K8S_POD_UID       // Unique pod identifier
}
```

**Organization environment variable:**
```bash
export AP_INSTANCE_ID=$(uuidgen)  # Or from environment
```

### service.namespace (RECOMMENDED)

Logical namespace for grouping services.

**Type**: `string`

**Example**: `ecommerce`, `payments`, `shop`

**Purpose:**
- Groups related services together
- Allows same service names in different namespaces
- Often maps to Kubernetes namespace or business domain

**Example:**
```javascript
{
  'service.namespace': 'ecommerce',
  'service.name': 'cart-service'
}
// Globally unique: ecommerce.cart-service
```

### service.version (RECOMMENDED)

Version of the service API or implementation.

**Type**: `string`

**Example**: `1.2.3`, `v2.0.0`, `2024-01-15-abc123`

**Format**: Any string - semantic versioning recommended but not required

**Use cases:**
- Track performance changes across versions
- Correlate errors with specific deployments
- Canary analysis and A/B testing

## Deployment Attributes

### deployment.environment (RECOMMENDED)

The environment where the service is running.

**Type**: `string`

**Example**: `dev`, `staging`, `production`, `uat`

**Requirements:**
- Use consistent naming across all services
- Common values: `production`, `staging`, `development`, `test`
- Does NOT affect service uniqueness (multiple environments can have same service)

**Organization convention:**
```bash
export AP_ENVIRONMENT=production  # Maps to deployment.environment
```

**Example:**
```javascript
{
  'service.name': 'order-service',
  'service.instance.id': 'pod-xyz-123',
  'deployment.environment': 'production'
}
// These are considered the same service in prod:
// - order-service on pod-xyz-123 (production)
// - order-service on pod-xyz-456 (production)

// But different from:
// - order-service on pod-abc-789 (staging)
```

## Telemetry SDK Attributes

These are automatically set by the OpenTelemetry SDK:

### telemetry.sdk.name (REQUIRED)

**Value**: `opentelemetry` (for official SDK)

**Purpose**: Identifies the SDK implementation

### telemetry.sdk.language (REQUIRED)

**Values**: `nodejs`, `python`, `java`, `go`, `dotnet`, etc.

**Purpose**: Identifies the programming language

### telemetry.sdk.version (REQUIRED)

**Example**: `1.18.0`

**Purpose**: SDK version for troubleshooting

## HTTP Semantic Conventions

### HTTP Server Spans (Incoming Requests)

**Span name**: `{http.request.method} {http.route}`

**Example**: `GET /api/orders/:id`

**Key attributes:**

| Attribute | Type | Example | Stability |
|-----------|------|---------|-----------|
| `http.request.method` | string | `GET`, `POST` | Stable |
| `http.response.status_code` | int | `200`, `404`, `500` | Stable |
| `http.route` | string | `/api/orders/:id` | Stable |
| `url.scheme` | string | `http`, `https` | Stable |
| `url.path` | string | `/api/orders/123` | Stable |
| `url.query` | string | `?filter=active` | Stable |
| `server.address` | string | `api.example.com` | Stable |
| `server.port` | int | `443` | Stable |
| `network.protocol.version` | string | `1.1`, `2`, `3` | Stable |
| `user_agent.original` | string | `Mozilla/5.0...` | Stable |
| `client.address` | string | `10.0.0.1` | Stable |

**Span kind**: `SERVER`

**Example span:**
```javascript
{
  name: 'GET /api/orders/:id',
  kind: 'SERVER',
  attributes: {
    'http.request.method': 'GET',
    'http.route': '/api/orders/:id',
    'http.response.status_code': 200,
    'url.scheme': 'https',
    'url.path': '/api/orders/123',
    'server.address': 'api.example.com',
    'server.port': 443
  }
}
```

### HTTP Client Spans (Outgoing Requests)

**Span name**: `{http.request.method} {server.address}`

**Example**: `POST api.payment.com`

**Key attributes:**

| Attribute | Type | Example | Stability |
|-----------|------|---------|-----------|
| `http.request.method` | string | `POST` | Stable |
| `http.response.status_code` | int | `201` | Stable |
| `url.full` | string | `https://api.payment.com/charge` | Stable |
| `server.address` | string | `api.payment.com` | Stable |
| `server.port` | int | `443` | Stable |
| `network.protocol.version` | string | `1.1` | Stable |

**Span kind**: `CLIENT`

### HTTP Status Code Semantics

| Status Code | Span Status | Description |
|-------------|-------------|-------------|
| 1xx | `UNSET` | Informational |
| 2xx | `UNSET` | Success |
| 3xx | `UNSET` | Redirection |
| 4xx | `UNSET` | Client error (not a span error) |
| 5xx | `ERROR` | Server error |

**Important**: Only 5xx status codes set span status to `ERROR`. 4xx codes are client mistakes, not service failures.

## Database Semantic Conventions

### Database Client Spans

**Span name**: `{db.operation} {db.name}.{db.collection.name}`

**Example**: `SELECT orders.customers`

**Key attributes:**

| Attribute | Type | Example | Stability |
|-----------|------|---------|-----------|
| `db.system` | string | `postgresql`, `mongodb`, `redis` | Stable |
| `db.name` | string | `ecommerce` | Stable |
| `db.operation` | string | `SELECT`, `INSERT`, `find` | Stable |
| `db.collection.name` | string | `orders`, `users` | Stable |
| `db.query.text` | string | `SELECT * FROM orders WHERE...` | Stable |
| `server.address` | string | `db.example.com` | Stable |
| `server.port` | int | `5432` | Stable |

**Span kind**: `CLIENT`

**SQL example:**
```javascript
{
  name: 'SELECT orders',
  kind: 'CLIENT',
  attributes: {
    'db.system': 'postgresql',
    'db.name': 'ecommerce',
    'db.operation': 'SELECT',
    'db.collection.name': 'orders',
    'db.query.text': 'SELECT * FROM orders WHERE user_id = ?',
    'server.address': 'postgres.internal',
    'server.port': 5432
  }
}
```

**NoSQL example:**
```javascript
{
  name: 'find users',
  kind: 'CLIENT',
  attributes: {
    'db.system': 'mongodb',
    'db.name': 'userdb',
    'db.operation': 'find',
    'db.collection.name': 'users',
    'server.address': 'mongo.internal',
    'server.port': 27017
  }
}
```

### Common Database Systems

| db.system Value | Database |
|-----------------|----------|
| `postgresql` | PostgreSQL |
| `mysql` | MySQL |
| `mssql` | Microsoft SQL Server |
| `mongodb` | MongoDB |
| `redis` | Redis |
| `elasticsearch` | Elasticsearch |
| `dynamodb` | Amazon DynamoDB |

## Messaging Semantic Conventions

### Message Producer Spans

**Span name**: `{messaging.operation} {messaging.destination.name}`

**Example**: `publish orders.created`

**Key attributes:**

| Attribute | Type | Example |
|-----------|------|---------|
| `messaging.system` | string | `kafka`, `rabbitmq`, `sqs` |
| `messaging.operation` | string | `publish`, `send`, `receive` |
| `messaging.destination.name` | string | `orders.created`, `user-events` |
| `messaging.message.id` | string | `abc123` |

**Span kind**: `PRODUCER`

### Message Consumer Spans

**Span kind**: `CONSUMER`

**Same attributes as producer, plus:**

| Attribute | Type | Example |
|-----------|------|---------|
| `messaging.consumer.id` | string | `consumer-group-1` |

## RPC Semantic Conventions

### gRPC

**Span name**: `{rpc.method}`

**Example**: `GetOrder`

**Key attributes:**

| Attribute | Type | Example |
|-----------|------|---------|
| `rpc.system` | string | `grpc` |
| `rpc.service` | string | `OrderService` |
| `rpc.method` | string | `GetOrder` |
| `rpc.grpc.status_code` | int | `0` (OK), `14` (UNAVAILABLE) |

## Kubernetes Attributes

When running in Kubernetes, include these resource attributes:

| Attribute | Type | Example |
|-----------|------|---------|
| `k8s.namespace.name` | string | `production` |
| `k8s.pod.name` | string | `order-service-5d7f8b-xyz` |
| `k8s.pod.uid` | string | `a1b2c3d4-e5f6-...` |
| `k8s.deployment.name` | string | `order-service` |
| `k8s.node.name` | string | `node-1` |
| `k8s.container.name` | string | `app` |

**Usually set automatically** by Kubernetes environment or OTel collector.

## Correlation Strategy

### Trace-to-Logs Correlation

**Key attributes to include in logs:**

```javascript
// In structured logs
{
  'service.name': 'order-service',
  'trace_id': '4bf92f3577b34da6a3ce929d0e0e4736',
  'span_id': '00f067aa0ba902b7',
  'deployment.environment': 'production'
}
```

**Loki labels from resource attributes:**
- `service.name` → `job` label
- `service.namespace` → `namespace` label
- `deployment.environment` → `environment` label
- `k8s.pod.name` → `pod` label

### Trace-to-Metrics Correlation

**Key attributes to include as metric dimensions:**

```javascript
// Good dimensions (low cardinality)
{
  'service.name': 'order-service',
  'http.request.method': 'POST',
  'http.response.status_code': 200,
  'deployment.environment': 'production'
}

// Avoid (high cardinality)
{
  'http.target': '/api/orders/12345',  // Unique per request
  'user.id': 'user-67890',             // Unique per user
  'trace.id': 'abc123...'               // Unique per trace
}
```

## Best Practices

### 1. Always Set service.name

This is the **most important** attribute for correlation:

```javascript
// ✅ Explicit service name
initOtelInstrumentation({
    componentName: 'order-service'
});

// ❌ Relying on default (results in "unknown_service:node")
// initOtelInstrumentation({});
```

### 2. Use Stable Conventions Where Available

Prefer stable attributes over experimental:

```javascript
// ✅ Stable HTTP conventions (as of 2024)
{
  'http.request.method': 'GET',
  'http.response.status_code': 200
}

// ⚠️ Deprecated (experimental, pre-stable)
{
  'http.method': 'GET',
  'http.status_code': 200
}
```

### 3. Include Environment Context

Always set `deployment.environment`:

```javascript
// Via environment variable
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production"

// Or in org instrumentation config
export AP_ENVIRONMENT=production
```

### 4. Consistent Naming Conventions

Use consistent patterns across services:

**Good:**
- Service names: `order-service`, `user-service`, `payment-service`
- Environments: `production`, `staging`, `development`
- Namespaces: `ecommerce`, `analytics`, `billing`

**Avoid:**
- Inconsistent casing: `OrderService`, `user-service`, `Payment_Service`
- Varied naming: `prod`, `production`, `prd`

### 5. Don't Over-Instrument

Not every attribute needs to be captured:

**Essential:**
- Service identity (name, namespace, version)
- Request metadata (method, status, route)
- Operation context (database, messaging system)

**Optional/Avoid:**
- Request/response bodies (security risk, high cardinality)
- User PII (privacy concerns)
- Sensitive data (credentials, tokens)

## Organization Integration

The `@your-org/instrumentation` package handles semantic conventions automatically:

```javascript
import {initOtelInstrumentation} from '@your-org/instrumentation';

initOtelInstrumentation({
    componentName: 'order-service'  // → service.name
});

// Automatically sets:
// - service.name (from componentName)
// - service.instance.id (from AP_INSTANCE_ID env var)
// - deployment.environment (from AP_ENVIRONMENT env var)
// - telemetry.sdk.* attributes
// - Standard HTTP, database, messaging conventions
```

**Required environment variables:**
```bash
export OTEL_SERVICE_NAME=order-service      # → service.name
export AP_INSTANCE_ID=$(uuidgen)            # → service.instance.id
export AP_ENVIRONMENT=production            # → deployment.environment
export AP_CLIENT=client-name                # Client-specific attribute
```

## Migration Guide

### From Experimental to Stable HTTP Conventions

If using OpenTelemetry SDK directly (not @your-org/instrumentation):

```bash
# Enable stable HTTP conventions
export OTEL_SEMCONV_STABILITY_OPT_IN=http
```

**Attribute mapping:**

| Experimental (Old) | Stable (New) |
|--------------------|--------------|
| `http.method` | `http.request.method` |
| `http.status_code` | `http.response.status_code` |
| `http.url` | `url.full` |
| `http.target` | `url.path` + `url.query` |
| `http.host` | `server.address` |
| `net.host.port` | `server.port` |

## Reference Links

- **OpenTelemetry Semantic Conventions**: https://opentelemetry.io/docs/specs/semconv/
- **Resource Conventions**: https://opentelemetry.io/docs/specs/semconv/resource/
- **HTTP Conventions**: https://opentelemetry.io/docs/specs/semconv/http/
- **Database Conventions**: https://opentelemetry.io/docs/specs/semconv/database/
- **Messaging Conventions**: https://opentelemetry.io/docs/specs/semconv/messaging/
- **Kubernetes Conventions**: https://opentelemetry.io/docs/specs/semconv/resource/k8s/
