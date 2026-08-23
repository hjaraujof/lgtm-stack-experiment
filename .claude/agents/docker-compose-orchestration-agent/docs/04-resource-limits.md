# Resource Management and Limits

**Purpose**: Guide for configuring CPU, memory, and restart policies in Docker Compose.

---

## Overview

Resource limits prevent containers from consuming excessive host resources. For the LGTM stack:
- **Memory limits** prevent OOM (Out of Memory) kills
- **CPU limits** ensure fair resource sharing
- **Restart policies** provide automatic recovery
- **Logging configuration** prevents disk space exhaustion

---

## Memory Limits

### Basic Memory Configuration

```yaml
services:
  loki:
    image: grafana/loki:latest
    mem_limit: 512m        # Hard limit: max memory
    mem_reservation: 256m  # Soft limit: guaranteed minimum
    memswap_limit: 1g      # Memory + swap total
```

### Memory Options

| Option | Description | Example | Default |
|--------|-------------|---------|---------|
| `mem_limit` | Maximum memory (hard limit) | `512m`, `2g` | Unlimited |
| `mem_reservation` | Guaranteed memory (soft limit) | `256m`, `1g` | None |
| `memswap_limit` | Total memory + swap | `1g`, `4g` | 2× mem_limit |
| `mem_swappiness` | Swap tendency (0-100) | `60` | Platform default |

**Units**: `b` (bytes), `k` (kilobytes), `m` (megabytes), `g` (gigabytes)

---

### mem_limit vs mem_reservation

```yaml
services:
  mimir:
    mem_limit: 2g        # Never exceed 2GB
    mem_reservation: 1g  # Try to guarantee 1GB
```

**Behavior**:
- Container always gets `mem_reservation` (1GB) if available
- Can use up to `mem_limit` (2GB) if host has free memory
- If host memory is tight, may be limited to `mem_reservation`

**Use case**: Mimir needs 1GB minimum but benefits from 2GB for caching

---

### Memory Swapping

```yaml
services:
  loki:
    mem_limit: 512m
    memswap_limit: 1g  # 512MB memory + 512MB swap
```

**memswap_limit values**:
- `-1`: Unlimited swap (dangerous)
- `0`: Disables swap limit checking (uses mem_limit only)
- Equal to `mem_limit`: No swap allowed
- Greater than `mem_limit`: Allows swap (difference = swap space)

**Example**:
```yaml
mem_limit: 512m
memswap_limit: 512m  # No swap (512m total = 512m memory + 0 swap)
```

---

### mem_swappiness

Controls kernel's tendency to swap memory to disk (0-100):

```yaml
services:
  tempo:
    mem_swappiness: 0  # Avoid swapping (prefer OOM kill)
```

| Value | Behavior | Use Case |
|-------|----------|----------|
| 0 | Disable swap | Performance-critical services |
| 60 | Default | Balanced |
| 100 | Aggressive swap | Low priority services |

**Recommendation for LGTM**: Set to `0` for performance

---

## CPU Limits

### CPU Configuration Options

```yaml
services:
  mimir:
    cpus: 2.5              # 2.5 CPU cores
    cpu_count: 2           # Limit to 2 physical CPUs
    cpu_shares: 1024       # Relative weight (default 1024)
    cpu_period: 100000     # CFS scheduler period (microseconds)
    cpu_quota: 50000       # CFS scheduler quota (microseconds)
    cpuset: "0,1"          # Use only CPUs 0 and 1
```

---

### cpus (Recommended)

Simplest and most intuitive way to limit CPUs:

```yaml
services:
  grafana:
    cpus: 1.0  # 1 full CPU core
```

**Examples**:
- `cpus: 0.5` = 50% of one CPU
- `cpus: 1.0` = 100% of one CPU (1 full core)
- `cpus: 2.0` = 2 full CPU cores
- `cpus: 0.25` = 25% of one CPU

---

### cpu_shares (Relative Weight)

Proportional CPU allocation when resources are constrained:

```yaml
services:
  mimir:
    cpu_shares: 2048  # 2x default weight

  tempo:
    cpu_shares: 1024  # 1x default weight (default)

  loki:
    cpu_shares: 512   # 0.5x default weight
```

**How it works**:
- Default weight: 1024
- When CPU is contended, shares determine proportional allocation
- Mimir gets 2× more CPU time than Tempo
- When CPU is idle, services can use more than their share

**Use case**: Prioritize Mimir (metrics queries) over log aggregation

---

### cpu_period and cpu_quota

Fine-grained control using CFS (Completely Fair Scheduler):

```yaml
services:
  loki:
    cpu_period: 100000  # 100ms period
    cpu_quota: 50000    # 50ms quota = 50% of one CPU
```

**Formula**: `CPU % = (cpu_quota / cpu_period) * 100`

**Examples**:
- `quota=50000, period=100000` = 50% of one CPU (0.5 cores)
- `quota=200000, period=100000` = 200% = 2 full CPUs
- `quota=25000, period=100000` = 25% of one CPU

**Recommendation**: Use `cpus` instead (simpler and clearer)

---

### cpuset

Pin container to specific CPU cores:

```yaml
services:
  mimir:
    cpuset: "0,1"  # Use only CPU cores 0 and 1
```

**Formats**:
- `"0,1,2"` - Specific cores
- `"0-3"` - Range of cores (0, 1, 2, 3)
- `"0-3,6,7"` - Mixed

**Use case**:
- NUMA (Non-Uniform Memory Access) optimization
- Isolate workloads on specific cores
- Avoid CPU migration overhead

---

## LGTM Stack Resource Recommendations

### Minimum Resources (Development)

```yaml
services:
  loki:
    mem_limit: 512m
    mem_reservation: 256m
    cpus: 0.5

  tempo:
    mem_limit: 512m
    mem_reservation: 256m
    cpus: 0.5

  mimir:
    mem_limit: 1g
    mem_reservation: 512m
    cpus: 1.0  # Mimir needs more CPU for queries

  grafana:
    mem_limit: 256m
    mem_reservation: 128m
    cpus: 0.5

  otel-collector:
    mem_limit: 256m
    mem_reservation: 128m
    cpus: 0.5
```

**Total minimum**: ~2.5GB RAM, ~3 CPU cores

---

### Production Resources

```yaml
services:
  loki:
    mem_limit: 4g
    mem_reservation: 2g
    cpus: 2.0
    mem_swappiness: 0

  tempo:
    mem_limit: 4g
    mem_reservation: 2g
    cpus: 2.0
    mem_swappiness: 0

  mimir:
    mem_limit: 8g
    mem_reservation: 4g
    cpus: 4.0  # Mimir benefits from more CPU
    mem_swappiness: 0

  grafana:
    mem_limit: 1g
    mem_reservation: 512m
    cpus: 1.0

  otel-collector:
    mem_limit: 1g
    mem_reservation: 512m
    cpus: 1.0
```

**Total production**: ~18GB RAM, ~10 CPU cores

---

## Restart Policies

Restart policies define container behavior on exit/failure:

```yaml
services:
  loki:
    restart: unless-stopped
```

### Restart Policy Options

| Policy | Behavior | Use Case |
|--------|----------|----------|
| `no` | Never restart | One-off tasks, init containers |
| `always` | Always restart (even after Docker daemon restart) | Critical services |
| `on-failure[:max-retries]` | Restart only on non-zero exit | Services that may intentionally exit |
| `unless-stopped` | Restart unless manually stopped | **Recommended for all LGTM services** |

---

### unless-stopped (Recommended)

```yaml
services:
  loki:
    restart: unless-stopped

  tempo:
    restart: unless-stopped

  mimir:
    restart: unless-stopped

  grafana:
    restart: unless-stopped

  otel-collector:
    restart: unless-stopped
```

**Behavior**:
- Restarts on failure
- Restarts on Docker daemon restart
- Does NOT restart if manually stopped (`docker compose stop`)

**Why recommended**:
- Automatic recovery from crashes
- Survives host reboots
- Respects manual stop commands

---

### always vs unless-stopped

```yaml
# always - restarts even if you manually stopped it
service-a:
  restart: always

# unless-stopped - respects manual stop
service-b:
  restart: unless-stopped
```

**Scenario**:
1. `docker compose stop loki` (manual stop)
2. `docker restart` (Docker daemon restarts)
3. With `always`: Loki starts automatically
4. With `unless-stopped`: Loki stays stopped

---

### on-failure

Restart only on failure (non-zero exit code):

```yaml
services:
  init:
    restart: on-failure:3  # Retry up to 3 times
```

**Use case**: Init containers that should exit successfully

---

## Logging Configuration

Prevent log files from filling disk:

```yaml
services:
  loki:
    logging:
      driver: "json-file"
      options:
        max-size: "10m"      # Max size per log file
        max-file: "3"        # Keep max 3 log files
        compress: "true"     # Compress rotated logs
```

### Logging Options

| Option | Description | Default | Recommendation |
|--------|-------------|---------|----------------|
| `max-size` | Max size before rotation | Unlimited | `10m` or `50m` |
| `max-file` | Number of log files to keep | Unlimited | `3` to `5` |
| `compress` | Compress rotated logs | `false` | `true` |
| `labels` | Log metadata labels | None | Service name |
| `env` | Include environment variables | None | Optional |

---

### Complete Logging Configuration

```yaml
services:
  loki:
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"
        labels: "service,environment"

  tempo:
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
        compress: "true"

  mimir:
    logging:
      driver: json-file
      options:
        max-size: "100m"  # Mimir more verbose
        max-file: "5"
        compress: "true"

  grafana:
    logging:
      driver: json-file
      options:
        max-size: "10m"  # Grafana less verbose
        max-file: "3"
        compress: "true"
```

---

### Alternative Logging Drivers

| Driver | Description | Use Case |
|--------|-------------|----------|
| `json-file` | Default, JSON formatted | **Recommended for LGTM** |
| `local` | Optimized file format | High-throughput logging |
| `syslog` | System log | Centralized logging |
| `journald` | systemd journal | systemd-based systems |
| `none` | Disable logging | Testing only |

---

## Deploy Specification (Alternative Syntax)

Docker Compose also supports the `deploy` section (primarily for Swarm):

```yaml
services:
  mimir:
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 4g
        reservations:
          cpus: '1.0'
          memory: 2g
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
```

**Note**: For non-Swarm deployments, use the top-level attributes (`mem_limit`, `cpus`, `restart`) instead.

---

## Complete LGTM Stack with Resource Limits

```yaml
services:
  init:
    image: grafana/tempo:latest
    user: root
    entrypoint: ["chown", "10001:10001", "/var/tempo"]
    volumes:
      - tempo-data:/var/tempo
    restart: on-failure:3
    mem_limit: 128m

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

  tempo:
    image: grafana/tempo:latest
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

## Monitoring Resource Usage

### Check Current Usage
```bash
docker stats
```

**Output**:
```
CONTAINER      CPU %    MEM USAGE / LIMIT    MEM %    NET I/O
loki           2.5%     450MiB / 2GiB        22%      1.2MB / 800kB
tempo          1.8%     380MiB / 2GiB        19%      900kB / 1.1MB
mimir          8.2%     1.5GiB / 4GiB        37%      2.3MB / 1.8MB
grafana        0.8%     120MiB / 512MiB      23%      400kB / 200kB
```

### Check Memory Details
```bash
docker inspect loki | grep -A 10 Memory
```

### Check for OOM Kills
```bash
docker inspect loki | grep OOMKilled
```

---

## Troubleshooting

### Container Killed by OOM

**Symptom**: Container exits with code 137

```bash
docker compose ps  # Shows Exit 137
docker compose logs loki  # May show "Killed"
```

**Solution**: Increase memory limit
```yaml
mem_limit: 4g  # Was 2g
```

---

### High CPU Usage

**Check which service**:
```bash
docker stats --no-stream
```

**Solution**: Reduce CPU limit or optimize service configuration

---

### Logs Filling Disk

**Check disk usage**:
```bash
du -sh /var/lib/docker/containers/*/*-json.log
```

**Solution**: Add logging configuration
```yaml
logging:
  options:
    max-size: "10m"
    max-file: "3"
```

---

## Best Practices

1. **Set memory limits for all services** - Prevent OOM on host
2. **Use `unless-stopped` restart policy** - Balance availability and control
3. **Configure log rotation** - Prevent disk space issues
4. **Set `mem_swappiness: 0`** - Avoid performance degradation
5. **Use `mem_reservation` for critical services** - Guarantee minimum resources
6. **Monitor with `docker stats`** - Track actual usage
7. **Test limits under load** - Ensure they're appropriate
8. **Document why limits are set** - Help future maintainers

---

## References

- Docker Compose resource limits: https://docs.docker.com/compose/compose-file/05-services/#resources
- Docker restart policies: https://docs.docker.com/compose/compose-file/05-services/#restart
- Docker logging: https://docs.docker.com/config/containers/logging/configure/
