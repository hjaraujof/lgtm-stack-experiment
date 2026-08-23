# Docker Compose Orchestration Agent - Reference Documentation

**Purpose**: Comprehensive reference documentation for the docker-compose-orchestration-agent to provide expert guidance on Docker Compose configuration for the LGTM observability stack.

---

## Overview

This documentation covers all aspects of Docker Compose orchestration for the LGTM stack (Loki, Grafana, Tempo, Mimir). Each document provides detailed information, examples, best practices, and troubleshooting guidance.

---

## Documentation Structure

### 01. Service Dependencies and Startup Ordering
**File**: `01-service-dependencies.md`

**Topics Covered**:
- `depends_on` attribute (short and long syntax)
- Condition types: `service_started`, `service_healthy`, `service_completed_successfully`
- Init container patterns for volume permissions
- Complete LGTM stack dependency configuration
- Dependency flow diagrams
- Common pitfalls and solutions
- Debugging dependency issues

**Key Insights**:
- Short syntax only ensures startup order, not readiness
- Use `condition: service_healthy` for critical dependencies
- Init containers solve permission issues (e.g., Tempo running as user 10001)
- `service_completed_successfully` ensures init containers finish before main services

**Current Stack Issues**:
- Tempo's init container uses short `depends_on` syntax (should use `service_completed_successfully`)
- No health checks defined (needed for `service_healthy` conditions)
- Grafana and OTel Collector start without waiting for backends to be ready

---

### 02. Health Checks
**File**: `02-health-checks.md`

**Topics Covered**:
- Health check configuration options (interval, timeout, retries, start_period, start_interval)
- Test command formats (CMD vs CMD-SHELL)
- Container health states (starting, healthy, unhealthy)
- Specific health checks for each LGTM component
- Advanced health check patterns (multi-step, functional, custom endpoints)
- Best practices and troubleshooting

**Key Insights**:
- Loki: `/ready` endpoint (`http://localhost:3100/ready`)
- Tempo: `/ready` endpoint (`http://localhost:3200/ready`)
- Mimir: `/ready` endpoint (`http://localhost:9009/ready`)
- Grafana: `/api/health` endpoint (`http://localhost:3000/api/health`)
- OTel Collector: Health endpoint on port 13133 (`http://localhost:13133/`)
- Use `wget --spider` for health checks (lightweight, no download)
- Set `start_period` to match actual initialization time

**Recommended Health Checks**:
```yaml
loki:
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3100/ready"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 10s
```

---

### 03. Volume Management
**File**: `03-volume-management.md`

**Topics Covered**:
- Volume types (named volumes, bind mounts, anonymous volumes)
- LGTM stack volume configuration
- Volume permission issues and solutions
- Volume options (read-only, volume-nocopy, drivers)
- Backup and restore procedures
- Volume management commands

**Key Insights**:
- Tempo requires special permissions (user 10001)
- Init container fixes permission issues by running as root
- Named volumes for production (Docker-managed)
- Bind mounts for development (easy access from host)
- Always mark config files as read-only (`:ro`)
- Regular backups essential for data persistence

**Current Stack Volumes**:
- `loki-data`: Stores log index and chunks at `/tmp/loki`
- `tempo-data`: Stores trace data and WAL at `/var/tempo` (needs user 10001 ownership)
- `mimir-data`: Stores metrics data at `/tmp/mimir`
- `grafana-data`: Stores dashboards and config at `/var/lib/grafana`

**Permission Solution**:
```yaml
init:
  image: grafana/tempo:latest
  user: root
  entrypoint: ["chown", "10001:10001", "/var/tempo"]
  volumes:
    - tempo-data:/var/tempo

tempo:
  depends_on:
    init:
      condition: service_completed_successfully
```

---

### 04. Resource Management and Limits
**File**: `04-resource-limits.md`

**Topics Covered**:
- Memory limits (`mem_limit`, `mem_reservation`, `memswap_limit`, `mem_swappiness`)
- CPU limits (`cpus`, `cpu_shares`, `cpu_period`, `cpu_quota`, `cpuset`)
- LGTM stack resource recommendations (development vs production)
- Restart policies (`no`, `always`, `on-failure`, `unless-stopped`)
- Logging configuration (log rotation, compression)
- Resource monitoring and troubleshooting

**Key Insights**:
- Set `mem_swappiness: 0` for performance (avoid swapping)
- Use `unless-stopped` restart policy for all LGTM services
- Configure log rotation to prevent disk space issues
- Mimir needs more resources (longer startup, more CPU for queries)
- Monitor with `docker stats` to validate limits

**Recommended Resources**:

**Development**:
- Loki: 512MB memory, 0.5 CPU
- Tempo: 512MB memory, 0.5 CPU
- Mimir: 1GB memory, 1.0 CPU
- Grafana: 256MB memory, 0.5 CPU
- OTel Collector: 256MB memory, 0.5 CPU
- Total: ~2.5GB RAM, ~3 CPU cores

**Production**:
- Loki: 4GB memory, 2.0 CPU
- Tempo: 4GB memory, 2.0 CPU
- Mimir: 8GB memory, 4.0 CPU
- Grafana: 1GB memory, 1.0 CPU
- OTel Collector: 1GB memory, 1.0 CPU
- Total: ~18GB RAM, ~10 CPU cores

**Log Rotation**:
```yaml
logging:
  driver: json-file
  options:
    max-size: "50m"
    max-file: "5"
    compress: "true"
```

---

### 05. Networking
**File**: `05-networking.md`

**Topics Covered**:
- Default network behavior and service discovery
- Custom networks (bridge, host, overlay, etc.)
- Port mapping (publishing ports to host)
- Multi-network configuration for isolation
- Network configuration options (IPAM, driver options, aliases)
- Service-level network options (MAC address, priority, static IPs)
- Network security and troubleshooting

**Key Insights**:
- Use bridge driver for single-host deployments
- Service discovery via DNS (service names)
- Publish ports only for external access
- Internal services don't need port publishing
- Bind sensitive services to `127.0.0.1` for security
- Use service names for internal communication (not IPs)

**Current Stack Network**:
```yaml
networks:
  lgtm-net:
    driver: bridge

services:
  loki:
    networks:
      - lgtm-net
    ports:
      - "3100:3100"  # External access
```

**Port Summary**:
| Port | Service | Purpose |
|------|---------|---------|
| 3000 | Grafana | Web UI |
| 3100 | Loki | Log ingestion/queries |
| 3200 | Tempo | Trace ingestion/queries |
| 9009 | Mimir | Metrics ingestion/queries |
| 4317 | OTel Collector | OTLP gRPC receiver |
| 4318 | OTel Collector | OTLP HTTP receiver |

**Internal Communication**:
- Grafana → `http://loki:3100`, `http://tempo:3200`, `http://mimir:9009`
- OTel Collector → `http://loki:3100/loki/api/v1/push`, `http://tempo:3200`, `http://prometheus:9090`

---

## Quick Reference

### Current docker-compose.yml Analysis

**Location**: `docker-compose.yml`

**Strengths**:
- Clean service definitions
- Named volumes for data persistence
- Custom network (lgtm-net)
- Init container for Tempo permissions
- Restart policy: `unless-stopped`
- Proper volume mounting for configs

**Improvements Needed**:
1. **Add health checks** for all services
2. **Use long syntax for depends_on** with conditions
3. **Add resource limits** (memory, CPU)
4. **Configure log rotation** to prevent disk space issues
5. **Set mem_swappiness: 0** for performance
6. **Mark config files as read-only** (`:ro`)

---

### Recommended Complete Configuration

A complete, production-ready docker-compose.yml with all best practices:

```yaml
networks:
  lgtm-net:
    driver: bridge

volumes:
  loki-data: {}
  tempo-data: {}
  mimir-data: {}
  grafana-data: {}

services:
  # Init container for Tempo volume permissions
  init:
    image: &tempoImage grafana/tempo:latest
    user: root
    entrypoint: ["chown", "10001:10001", "/var/tempo"]
    volumes:
      - tempo-data:/var/tempo
    restart: on-failure:3
    mem_limit: 128m

  # Loki - log aggregation backend
  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml:ro
      - loki-data:/tmp/loki
    command: -config.file=/etc/loki/config.yaml
    networks:
      - lgtm-net
    restart: unless-stopped
    mem_limit: 2g
    mem_reservation: 1g
    cpus: 1.0
    mem_swappiness: 0
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"
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
      - ./config/tempo-config.yaml:/etc/tempo/config.yaml:ro
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
        required: false
    mem_limit: 2g
    mem_reservation: 1g
    cpus: 1.0
    mem_swappiness: 0
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"
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
      - ./config/mimir-config.yaml:/etc/mimir/config.yaml:ro
      - mimir-data:/tmp/mimir
    networks:
      - lgtm-net
    restart: unless-stopped
    mem_limit: 4g
    mem_reservation: 2g
    cpus: 2.0
    mem_swappiness: 0
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"
        compress: "true"
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9009/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  # Grafana - visualization frontend
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana/provisioning/:/etc/grafana/provisioning/:ro
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
    mem_limit: 512m
    mem_reservation: 256m
    cpus: 0.5
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
        compress: "true"
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
      - ./config/otel-collector-config.yaml:/etc/otelcol-contrib/config.yaml:ro
    ports:
      - "4317:4317"
      - "4318:4318"
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
    mem_limit: 512m
    mem_reservation: 256m
    cpus: 0.5
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:13133/"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s
```

---

## Common Patterns and Best Practices

### 1. Always Use Health Checks
- Define health checks for all services
- Use appropriate `start_period` for initialization time
- Use lightweight checks (`wget --spider` or dedicated health endpoints)

### 2. Proper Dependency Management
- Use `condition: service_healthy` for critical dependencies
- Use `condition: service_completed_successfully` for init containers
- Mark optional dependencies with `required: false`

### 3. Resource Limits
- Set memory limits to prevent OOM
- Set CPU limits for fair resource sharing
- Use `mem_swappiness: 0` for performance
- Monitor with `docker stats`

### 4. Restart Policies
- Use `unless-stopped` for all main services
- Use `on-failure:N` for init containers
- Never use `no` for production services

### 5. Volume Management
- Use named volumes for data
- Use bind mounts for configs (marked `:ro`)
- Handle permissions with init containers
- Regular backups

### 6. Networking
- Use custom networks for clarity
- Use service names for internal communication
- Only publish ports that need external access
- Consider binding to `127.0.0.1` for security

### 7. Logging
- Configure log rotation (max-size, max-file)
- Enable compression
- Monitor disk usage

---

## Troubleshooting Quick Reference

### Service Won't Start
1. Check logs: `docker compose logs -f <service>`
2. Check dependencies: Are dependent services healthy?
3. Check permissions: Volume permission issues?
4. Check resources: Memory/CPU limits too low?

### Health Check Failing
1. Test manually: `docker compose exec <service> <health-check-command>`
2. Check tool exists: `docker compose exec <service> which curl`
3. Check endpoint: `docker compose exec <service> curl -v http://localhost:<port>/ready`
4. Check start_period: Is initialization time too short?

### Can't Connect Between Services
1. Check network: `docker network inspect <network-name>`
2. Test DNS: `docker compose exec <service> ping <target-service>`
3. Check firewall: `sudo ufw status`
4. Verify both on same network

### Out of Memory
1. Check usage: `docker stats`
2. Increase limit: `mem_limit: 4g`
3. Check for leaks: Review service logs
4. Add swap: `memswap_limit: 8g`

### Disk Space Issues
1. Check logs: `du -sh /var/lib/docker/containers/*/*-json.log`
2. Add log rotation: See logging config above
3. Prune volumes: `docker volume prune`
4. Check volume size: `docker system df -v`

---

## External References

- **Docker Compose Documentation**: https://docs.docker.com/compose/
- **Docker Compose File Reference**: https://docs.docker.com/compose/compose-file/
- **Health Check Best Practices**: https://last9.io/blog/docker-compose-health-checks/
- **Grafana LGTM Stack**: https://grafana.com/docs/opentelemetry/docker-lgtm/
- **LGTM Setup Guide**: https://www.hostinger.com/tutorials/how-to-set-up-lgtm-stack
- **Docker Networking**: https://docs.docker.com/network/
- **Docker Volumes**: https://docs.docker.com/storage/volumes/

---

## Using This Documentation

**For the agent**:
1. Read the relevant document based on user question
2. Provide specific examples from LGTM stack
3. Reference current docker-compose.yml issues
4. Suggest improvements based on best practices
5. Always include troubleshooting steps

**For developers**:
1. Use as reference for Docker Compose patterns
2. Apply best practices to LGTM stack
3. Troubleshoot issues with provided commands
4. Customize resource limits based on workload
5. Test health checks before deploying

---

## Document Maintenance

**Last Updated**: 2025-11-28

**Version**: 1.0.0

**Contributors**: Research conducted via Docker documentation, Grafana LGTM docs, and Docker Compose best practices

**Next Review**: When Docker Compose or LGTM stack components receive major updates
