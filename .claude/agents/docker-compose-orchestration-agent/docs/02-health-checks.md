# Health Checks in Docker Compose

**Purpose**: Comprehensive guide to implementing effective health checks for LGTM stack components.

---

## Overview

Health checks verify that services are not just running, but actually ready to handle requests. Docker Compose uses health check results to:

1. Determine when a service is truly "healthy"
2. Control startup order with `depends_on: condition: service_healthy`
3. Enable container orchestrators to restart unhealthy services

**Critical Distinction**: A container in "running" state doesn't mean the application inside is operational. Health checks validate actual readiness.

---

## Health Check Configuration

### Basic Syntax

```yaml
services:
  web:
    image: nginx
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
      start_interval: 5s
```

### Configuration Options

| Option | Description | Default | Best Practice |
|--------|-------------|---------|---------------|
| `test` | Command to run (CMD or CMD-SHELL format) | None | Use CMD format for reliability |
| `interval` | Time between checks | 30s | 10-30s for backends, 30-60s for frontends |
| `timeout` | Max time for check to complete | 30s | 5-10s (must complete quickly) |
| `retries` | Consecutive failures before unhealthy | 3 | 3-5 retries |
| `start_period` | Grace period before counting failures | 0s | Match service initialization time |
| `start_interval` | Check frequency during grace period | 5s | 5s (faster checks during startup) |

---

## Test Command Formats

### CMD Format (Recommended)

Executes command directly without shell, providing better reliability and performance:

```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
```

### CMD-SHELL Format

Runs command in a shell, allowing shell features like pipes and variables:

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"]
```

Or as a string (equivalent to CMD-SHELL):

```yaml
healthcheck:
  test: curl -f http://localhost:8080/health || exit 1
```

### NONE Format

Disables health check inherited from base image:

```yaml
healthcheck:
  disable: true
```

---

## Container Health States

| State | Description | Transition |
|-------|-------------|------------|
| `starting` | Health checks running, failures ignored during `start_period` | → healthy or unhealthy |
| `healthy` | Check passed with exit code 0 | → unhealthy after `retries` failures |
| `unhealthy` | Check failed `retries` times consecutively | → healthy after successful check |

**View health status**:
```bash
docker compose ps
docker inspect <container-id> | grep Health -A 20
```

---

## Health Checks for LGTM Components

### Loki (Log Aggregation)

Loki provides a `/ready` endpoint that confirms it's accepting log data.

```yaml
loki:
  image: grafana/loki:latest
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3100/ready"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 10s
```

**Why this works**:
- `/ready` endpoint returns 200 when Loki is ready to ingest logs
- `wget --spider` checks without downloading content
- Minimal overhead, fast response

**Alternative with curl**:
```yaml
test: ["CMD", "curl", "-f", "http://localhost:3100/ready"]
```

**Common Issues**:
- "Ingester not ready: waiting for 15s" - This is normal startup behavior, covered by `start_period`
- Missing `wget` or `curl` in image - Grafana images include these by default

---

### Tempo (Distributed Tracing)

Tempo provides `/ready` endpoint for health checks.

```yaml
tempo:
  image: grafana/tempo:latest
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3200/ready"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 10s
```

**Why this works**:
- Confirms Tempo is ready to accept trace data
- Fast, reliable check

**Alternative with Tempo-specific endpoint**:
```yaml
test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3200/status/buildinfo"]
```

---

### Mimir (Metrics Storage)

Mimir (Prometheus-compatible) provides `/ready` endpoint.

```yaml
mimir:
  image: grafana/mimir:latest
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9009/ready"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s  # Mimir takes longer to initialize
```

**Why longer start_period**:
- Mimir runs in monolithic mode (`-target=all`)
- Multiple internal components initialize
- 30s grace period accounts for startup time

**Alternative Prometheus check**:
```yaml
test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9009/-/ready"]
```

---

### Grafana (Visualization)

Grafana provides `/api/health` endpoint.

```yaml
grafana:
  image: grafana/grafana:latest
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/api/health"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 10s
```

**Why this works**:
- `/api/health` returns JSON with database and overall status
- More thorough than checking just root endpoint
- Ensures Grafana can connect to its SQLite database

**Alternative simpler check**:
```yaml
test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/"]
```

---

### OpenTelemetry Collector

OTel Collector exposes health endpoint on port 13133.

```yaml
otel-collector:
  image: otel/opentelemetry-collector-contrib:latest
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:13133/"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 5s
```

**Why this works**:
- Health extension enabled by default on port 13133
- Fast startup, minimal grace period needed
- Confirms collector is ready to receive OTLP data

**Note**: Must ensure health check extension is configured in `otel-collector-config.yaml`:
```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
```

---

## Advanced Health Check Patterns

### Multi-Step Health Check Script

For complex health requirements, use a shell script:

```yaml
healthcheck:
  test: ["CMD", "sh", "-c", "/app/health-check.sh"]
  interval: 15s
  timeout: 10s
  retries: 3
```

**health-check.sh** example:
```bash
#!/bin/sh

# Check main process is alive
pgrep -f my-service > /dev/null || exit 1

# Check HTTP endpoint responds
curl -f http://localhost:8080/health > /dev/null 2>&1 || exit 1

# Check dependency connectivity
curl -f http://database:5432 > /dev/null 2>&1 || exit 1

# All checks passed
exit 0
```

---

### Functional Health Check (End-to-End)

Verify critical workflows work:

```bash
#!/bin/bash
# Create test resource
curl -s -X POST -d '{"test":"data"}' \
  -H "Content-Type: application/json" \
  http://localhost:8080/api/test > /dev/null || exit 1

# Verify resource exists
curl -s http://localhost:8080/api/test | grep -q "test" || exit 1

# Clean up
curl -s -X DELETE http://localhost:8080/api/test > /dev/null || exit 1

exit 0
```

---

### Custom Health Endpoint in Application

Best practice: Implement `/health` endpoint that checks dependencies:

**Node.js Example**:
```javascript
app.get('/health', async (req, res) => {
  try {
    // Check database
    await db.query('SELECT 1');

    // Check Redis
    await redis.ping();

    // Check external API
    const response = await fetch('http://backend:8080/health');
    if (!response.ok) throw new Error('Backend unhealthy');

    res.status(200).json({ status: 'healthy' });
  } catch (err) {
    res.status(500).json({
      status: 'unhealthy',
      error: err.message
    });
  }
});
```

**Docker Compose**:
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
```

---

## Health Check Best Practices

### 1. Use Appropriate Intervals

```yaml
# Backend services (databases, caches)
interval: 10s
timeout: 5s
retries: 5
start_period: 10-30s

# Application services
interval: 15s
timeout: 10s
retries: 3
start_period: 15-30s

# Frontend services
interval: 30s
timeout: 10s
retries: 3
start_period: 10s
```

### 2. Set Realistic Start Periods

Match `start_period` to actual initialization time:

- **Loki**: 10s (fast startup)
- **Tempo**: 10s (fast startup)
- **Mimir**: 30s (slower, multiple components)
- **Grafana**: 10s (fast, but database initialization)
- **OTel Collector**: 5s (very fast)

### 3. Keep Health Checks Lightweight

**Bad** (expensive):
```yaml
test: ["CMD", "sh", "-c", "curl http://localhost:8080/api/full-system-test"]
```

**Good** (lightweight):
```yaml
test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
```

### 4. Ensure Health Check Tools Exist

Alpine-based images often lack `curl`:

```dockerfile
FROM alpine:latest
RUN apk add --no-cache curl wget
```

Or use `wget` instead (usually pre-installed):
```yaml
test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/health"]
```

### 5. Use Exit Codes Correctly

- **Exit 0**: Healthy
- **Exit 1**: Unhealthy
- **Other**: Unhealthy

```bash
# Correct
curl -f http://localhost:8080/health || exit 1

# Also correct (curl -f exits 22 on HTTP error)
curl -f http://localhost:8080/health
```

### 6. Log Health Check Failures

Enable debugging for failed checks:

```yaml
healthcheck:
  test: ["CMD", "sh", "-c", "curl -f http://localhost:8080/health || (echo 'Health check failed' >&2; exit 1)"]
```

---

## Troubleshooting Health Checks

### Container Keeps Restarting

**Symptoms**: Container restarts repeatedly, never becomes healthy.

**Debug**:
```bash
# Check logs
docker compose logs -f <service>

# Run health check manually
docker compose exec <service> curl -f http://localhost:8080/health

# Check if curl/wget exists
docker compose exec <service> which curl
```

**Common Causes**:
1. Health check command not found in image
2. Service taking longer than `start_period` to initialize
3. Wrong port or endpoint
4. Service genuinely failing to start

---

### Health Check Passes But Service Not Ready

**Symptoms**: Container marked healthy, but connections fail.

**Cause**: Health check too shallow (e.g., only checking if process exists).

**Solution**: Use endpoint that verifies actual readiness:

**Bad**:
```yaml
test: ["CMD", "pgrep", "postgres"]
```

**Good**:
```yaml
test: ["CMD", "pg_isready", "-U", "postgres"]
```

---

### Health Check Takes Too Long

**Symptoms**: Timeouts, slow startup.

**Solution**: Reduce `timeout` or optimize health check:

```yaml
# Before
timeout: 30s
test: ["CMD", "sh", "-c", "complex-script.sh"]

# After
timeout: 5s
test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
```

---

## Complete LGTM Stack with Health Checks

```yaml
services:
  init:
    image: grafana/tempo:latest
    user: root
    entrypoint: ["chown", "10001:10001", "/var/tempo"]
    volumes:
      - tempo-data:/var/tempo

  loki:
    image: grafana/loki:latest
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3100/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  tempo:
    image: grafana/tempo:latest
    depends_on:
      init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3200/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  mimir:
    image: grafana/mimir:latest
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9009/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  grafana:
    image: grafana/grafana:latest
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

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    depends_on:
      loki:
        condition: service_healthy
      tempo:
        condition: service_healthy
      mimir:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:13133/"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s
```

---

## References

- Docker Compose healthcheck: https://docs.docker.com/compose/compose-file/05-services/#healthcheck
- Docker healthcheck best practices: https://last9.io/blog/docker-compose-health-checks/
- LGTM Stack health endpoints: https://grafana.com/docs/opentelemetry/docker-lgtm/
