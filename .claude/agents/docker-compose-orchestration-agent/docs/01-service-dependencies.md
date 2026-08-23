# Service Dependencies and Startup Ordering

**Purpose**: Guide for managing service dependencies and controlling startup order in Docker Compose.

---

## Overview

Docker Compose provides mechanisms to control when and how services start relative to each other. This is critical for observability stacks where services depend on each other (e.g., Grafana depends on Loki, Tempo, and Mimir being healthy).

---

## depends_on Attribute

The `depends_on` attribute defines dependencies between services, controlling startup order and optionally waiting for health checks.

### Short Syntax (Basic Startup Order)

The short syntax only ensures containers start in order, but does NOT wait for services to be ready:

```yaml
services:
  web:
    image: nginx
    depends_on:
      - db
      - redis

  db:
    image: postgres

  redis:
    image: redis
```

**Behavior**:
- Docker Compose creates `db` and `redis` before `web`
- Docker Compose removes `web` before `db` and `redis`
- **Does NOT wait** for `db` or `redis` to be ready

**Problem**: The `web` service might start before the database accepts connections, causing errors.

---

## Long Syntax (Health-Based Dependencies)

The long syntax provides fine-grained control with conditions:

```yaml
services:
  web:
    image: nginx
    depends_on:
      db:
        condition: service_healthy
        restart: true
      redis:
        condition: service_started
        required: false

  db:
    image: postgres
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
```

### Condition Types

| Condition | Behavior | Use Case |
|-----------|----------|----------|
| `service_started` | Wait for container to start (default) | Basic ordering, no health check needed |
| `service_healthy` | Wait for health check to pass | Database/backend must be ready |
| `service_completed_successfully` | Wait for container to exit with code 0 | Init containers, migrations |

### Additional Options

- **`restart: true`** (Compose 2.17.0+): Restart this service when the dependency is updated
- **`required: false`** (Compose 2.20.0+): Only warn if dependency fails, don't block startup

---

## Init Containers Pattern

Init containers run one-time setup tasks before main services start. Use `service_completed_successfully` to ensure they finish before dependent services start.

### Example: Volume Permissions for Tempo

From the current `docker-compose.yml`:

```yaml
services:
  # Tempo runs as user 10001, and docker compose creates the volume as root.
  # As such, we need to chown the volume in order for Tempo to start correctly.
  init:
    image: &tempoImage grafana/tempo:latest
    user: root
    entrypoint:
      - "chown"
      - "10001:10001"
      - "/var/tempo"
    volumes:
      - tempo-data:/var/tempo

  tempo:
    image: *tempoImage
    container_name: tempo
    volumes:
      - ./config/tempo-config.yaml:/etc/tempo/config.yaml
      - tempo-data:/var/tempo
    command: -config.file=/etc/tempo/config.yaml
    networks:
      - lgtm-net
    restart: unless-stopped
    depends_on:
      - init
      - loki
```

**Current Issue**: `depends_on: - init` uses short syntax, which doesn't guarantee the `init` container completes successfully.

**Recommended Fix**:

```yaml
tempo:
  depends_on:
    init:
      condition: service_completed_successfully
    loki:
      condition: service_healthy
```

---

## Complete LGTM Stack Dependency Example

Here's how the LGTM stack should be configured with proper health checks and dependencies:

```yaml
services:
  # Init container for Tempo volume permissions
  init:
    image: &tempoImage grafana/tempo:latest
    user: root
    entrypoint: ["chown", "10001:10001", "/var/tempo"]
    volumes:
      - tempo-data:/var/tempo

  # Loki - log aggregation backend
  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml
      - loki-data:/tmp/loki
    command: -config.file=/etc/loki/config.yaml
    networks:
      - lgtm-net
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3100/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # Tempo - distributed tracing backend
  tempo:
    image: *tempoImage
    container_name: tempo
    ports:
      - "3200:3200"
    volumes:
      - ./config/tempo-config.yaml:/etc/tempo/config.yaml
      - tempo-data:/var/tempo
    command: -config.file=/etc/tempo/config.yaml
    networks:
      - lgtm-net
    restart: unless-stopped
    depends_on:
      init:
        condition: service_completed_successfully
      loki:
        condition: service_healthy
        required: false  # Optional dependency
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3200/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # Mimir - metrics backend
  mimir:
    image: grafana/mimir:latest
    container_name: mimir
    command: -target=all -config.file=/etc/mimir/config.yaml
    ports:
      - "9009:9009"
    volumes:
      - ./config/mimir-config.yaml:/etc/mimir/config.yaml
      - mimir-data:/tmp/mimir
    networks:
      - lgtm-net
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9009/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s  # Mimir takes longer to start

  # Grafana - visualization frontend
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana/provisioning/:/etc/grafana/provisioning/
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    networks:
      - lgtm-net
    restart: unless-stopped
    depends_on:
      loki:
        condition: service_healthy
      tempo:
        condition: service_healthy
      mimir:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  # OpenTelemetry Collector
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: otel-collector
    volumes:
      - ./config/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml
    ports:
      - "4317:4317"  # OTLP gRPC
      - "4318:4318"  # OTLP HTTP
    networks:
      - lgtm-net
    depends_on:
      loki:
        condition: service_healthy
      tempo:
        condition: service_healthy
      mimir:
        condition: service_healthy
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:13133/"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s

volumes:
  loki-data: {}
  tempo-data: {}
  mimir-data: {}
  grafana-data: {}

networks:
  lgtm-net:
    driver: bridge
```

---

## Dependency Flow Diagram

```
init (completes)
  ↓
loki (healthy)
  ↓
tempo (healthy) + mimir (healthy)
  ↓
grafana (healthy) + otel-collector (healthy)
```

---

## Common Pitfalls

### 1. Using Short Syntax Without Health Checks

**Problem**:
```yaml
grafana:
  depends_on:
    - loki
    - tempo
    - mimir
```

Grafana starts as soon as containers exist, not when backends are ready.

**Solution**: Use `condition: service_healthy` with proper health checks.

---

### 2. Missing Health Checks

**Problem**:
```yaml
grafana:
  depends_on:
    loki:
      condition: service_healthy
```

If `loki` has no health check defined, Compose fails with an error.

**Solution**: Always define health checks for services used with `service_healthy`.

---

### 3. Circular Dependencies

Docker Compose does NOT support circular dependencies. Design services to have clear dependency hierarchies.

**Invalid**:
```yaml
service-a:
  depends_on:
    - service-b

service-b:
  depends_on:
    - service-a
```

---

## Best Practices for LGTM Stack

1. **Always use health checks** for backend services (Loki, Tempo, Mimir)
2. **Use `service_healthy` condition** for critical dependencies
3. **Set appropriate `start_period`** for services with slow initialization
4. **Use init containers** for one-time setup tasks (permissions, migrations)
5. **Make optional dependencies explicit** with `required: false`
6. **Include restart policies** to handle transient failures
7. **Test startup order** with `docker compose up` and `docker compose logs -f`

---

## Debugging Dependency Issues

### Check Service Status
```bash
docker compose ps
```

### View Logs for Failed Service
```bash
docker compose logs -f <service-name>
```

### Restart Specific Service
```bash
docker compose restart <service-name>
```

### Force Recreate Services
```bash
docker compose up -d --force-recreate
```

---

## References

- Docker Compose depends_on: https://docs.docker.com/compose/compose-file/05-services/#depends_on
- Docker Compose healthcheck: https://docs.docker.com/compose/compose-file/05-services/#healthcheck
- Grafana LGTM Stack: https://grafana.com/docs/opentelemetry/docker-lgtm/
