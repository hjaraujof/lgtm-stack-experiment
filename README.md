# Local LGTM Stack Experiment

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
