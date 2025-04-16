# Local LGTM Stack

This project provides a local development environment for the LGTM (Loki, Grafana, Tempo, Mimir) observability stack, orchestrated using Docker Compose. It includes an OpenTelemetry Collector for receiving OTLP data and forwarding it to the appropriate backends.

## Components

The stack consists of the following services running in Docker containers:

* **Grafana:** Visualization dashboard (Port `3000`). Default credentials: `admin`/`admin`.
* **Loki:** Log aggregation system (Port `3100`).
* **Tempo:** Distributed tracing backend (Port `3200` for API/UI, OTLP ports handled by Collector).
* **Mimir:** Prometheus-compatible metrics backend (Port `9009`).
* **OTel Collector:** Receives OTLP data (gRPC port `4317`, HTTP port `4318`) and exports to Loki, Tempo, and Mimir.

## Directory Structure

* `config/`: Contains configuration files for the services.
  * `loki-config.yaml`: Loki configuration.
  * `tempo-config.yaml`: Tempo configuration.
  * `mimir-config.yaml`: Mimir configuration.
  * `otel-collector-config.yaml`: OpenTelemetry Collector configuration.
  * `grafana/provisioning/datasources/datasources.yaml`: Grafana datasource provisioning.
* `data/`: Stores persistent data for each service (created automatically via Docker volumes mapped from this directory).
* `docker-compose.yml`: Defines the services, networks, and volumes for the stack.

*(Note: Other files like `.clinerules` and `memory-bank/` are used for development assistance and are not part of the core stack deployment.)*

## Prerequisites

* Docker Engine
* Docker Compose (v2 - `docker compose` command)

## Running the Stack

1. **Navigate** to this directory (`lgtm-stack-experiment`) in your terminal.
2. **Start** the stack:

    ```bash
    docker compose up -d
    ```

    This will pull the necessary images (if not already present) and start all containers in detached mode.

## Accessing Services

* **Grafana:** `http://localhost:3000` (Login: `admin`/`admin`)
* **Loki:** (Usually accessed via Grafana datasource) Push API at `http://localhost:3100`
* **Tempo:** (Usually accessed via Grafana datasource) API at `http://localhost:3200`
* **Mimir:** (Usually accessed via Grafana datasource) API at `http://localhost:9009`
* **OTel Collector OTLP Endpoint (for applications):**
  * gRPC: `grpc://localhost:4317` (use insecure connection)
  * HTTP: `http://localhost:4318`

## Sending Data (Example: Node.js Application)

Configure your application's OpenTelemetry SDK to export traces/logs/metrics via OTLP to the OTel Collector's endpoint (`http://localhost:4318` or `grpc://localhost:4317`).

**Example Environment Variables for Node.js:**

```bash
export OTEL_SERVICE_NAME="your-service-name"
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL="http/protobuf" # or grpc
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318" # Collector's HTTP endpoint
# For gRPC use: export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
# For gRPC use: export OTEL_EXPORTER_OTLP_INSECURE="true"

# To send logs/metrics via OTLP to the collector as well:
# export OTEL_LOGS_EXPORTER="otlp"
# export OTEL_METRICS_EXPORTER="otlp"

# Start your app (ensure instrumentation is loaded, e.g., via -r flag)
node your-app.js
```

Alternatively, configure the exporter directly in your SDK setup (see `connectors-data-api/connectors-data-api/instrumentation.ts` for an example of SDK-based trace exporter configuration).

## Stopping the Stack

```bash
docker compose down
```

This stops and removes the containers but preserves the data in the `./data` directory.

## Cleaning Up Data

To remove all persisted data, simply delete the contents of the `./data` directory:

```bash
sudo rm -rf ./data/*
```

*(Use `sudo` if necessary due to Docker volume permissions)*

## Instrumentation Patterns (`connectors-data-api/utils/instrumentation`)

The `connectors-data-api` project includes reusable utilities, primarily decorators, for applying consistent manual OpenTelemetry tracing to controller classes and methods. These patterns can be adapted for other similar Node.js projects using Inversify and Express.

### Decorators

1. **`@traceControllerMethod(options?: ControllerMethodOtelTracingOptions)`**:
    * **Purpose:** A method decorator applied to public methods within a controller class (typically request handlers like `get`, `create`, `update`).
    * **Function:** It registers the decorated method for tracing. It doesn't perform tracing itself but makes the method discoverable by the class decorator.
    * **Options:** Accepts an optional `options` object (`ControllerMethodOtelTracingOptions`) to customize tracing behavior for that specific method:
        * `spanName`: Override the default span name (which is `ClassName.methodName`).
        * `attributes`: An object containing additional custom attributes to add to the span.
        * `captureBody`: Boolean flag (default `false`) to capture the request body as a span attribute (`http.request.body`).
        * `maxBodySize`: Maximum size (in characters) for the captured request body (default `1000`). Truncated if larger.
        * `includeProtectedProps`: Array of protected property names from the class instance to include as span attributes (e.g., `controller.propertyName`). `docType` and `useFlatDocument` are often included by default if present.

2. **`@traceControllerClass(tracerName?: string)`**:
    * **Purpose:** A class decorator applied to the controller class itself (e.g., `ControllerBase` or specific implementations).
    * **Function:** This decorator activates the tracing for methods marked with `@traceControllerMethod`. It wraps these methods to:
        * Start an OpenTelemetry span when the method is called.
        * Extract any incoming trace context from request headers (enabling distributed tracing).
        * Automatically add standard attributes:
            * `controller.name`, `controller.method`
            * `http.request.method`, `http.route`, `url.full`
            * Request parameters (`params.*`)
            * Request query (`http.query` as stringified JSON)
            * Context info like `application`, `franchiseGroups`, `docType`.
            * Optional request body (`http.request.body`) if enabled via `@traceControllerMethod` options.
            * Optional protected properties if configured via `@traceControllerMethod` options.
        * Record any exceptions thrown by the method onto the span.
        * Set the span status (OK or ERROR).
        * End the span when the method finishes.
    * **Arguments:** Takes an optional `tracerName` string (defaults to `'controller-tracer'`) to identify the source of the spans.

### Usage Example

```typescript
import { trace, SpanStatusCode } from '@opentelemetry/api';
import { injectable } from 'inversify';
import { BaseHttpController, httpGet, httpPost } from 'inversify-express-utils';
import { traceControllerClass, traceControllerMethod } from './utils/instrumentation/decorators'; // Adjust path

@injectable()
@traceControllerClass() // Apply class decorator
export class MyController extends BaseHttpController {

    @httpGet('/')
    @traceControllerMethod({ attributes: { 'custom.tag': 'example' } }) // Apply method decorator
    public async getResource(req: Request, res: Response) {
        // ... handler logic ...
        // Span is automatically created/ended around this method execution
    }

    @httpPost('/')
    @traceControllerMethod({ captureBody: true, maxBodySize: 500 }) // Capture request body
    public async createResource(req: Request, res: Response) {
        // ... handler logic ...
    }
}
```

### How it Relates to the LGTM Stack

When these decorators are used in an application (like `connectors-data-api`) that is configured to export OTel data (as set up in its `instrumentation.ts`):

1. The `@traceControllerClass` wrapper creates spans for methods marked with `@traceControllerMethod`.
2. These spans, along with their attributes and any recorded errors, are processed by the application's OTel SDK.
3. The SDK's configured exporter (e.g., OTLP HTTP exporter pointing to `http://localhost:4318`) sends the span data to the **OTel Collector** running in the `lgtm-stack-experiment`.
4. The OTel Collector receives the data and, based on its `otel-collector-config.yaml`, forwards the traces to **Tempo** (`http://tempo:4318`).
5. Tempo stores the traces.
6. **Grafana** (connected to Tempo as a datasource) can then be used to query, visualize, and explore these traces, providing detailed insight into the execution flow and performance of the decorated controller methods.

This pattern provides a standardized way to gain visibility into controller actions within the context of the overall request trace, leveraging the deployed LGTM stack.
