# Task: LGTM Stack Storage and Retention Configuration Fixes

**Created:** 2025-11-28
**Status:** Completed

## Problem Summary

The LGTM stack has critical configuration issues causing:
1. **Trace data loss** - Storage paths don't match volume mounts
2. **Short retention** - Traces only kept for ~1-2 hours
3. **Logs not reaching Loki** - Debug exporter instead of Loki exporter
4. **Missing reliability features** - No health checks, retry configs, or pinned versions

## Approach

Fix all storage path mismatches, increase retention to 14 days, add proper Loki log exporter, and improve overall stack stability with health checks and reliability configurations.

**Compatibility constraint:** Maintain OTLP HTTP on port 4318 for `@your-org/instrumentation` compatibility.

---

## Tasks

### Phase 1: Critical Storage Fixes

#### 1. Fix Tempo storage paths and retention
**File:** `config/tempo-config.yaml`

**Changes:**
```yaml
# Line 31-38: Fix storage path to match docker-compose volume mount
storage:
  trace:
    backend: local
    local:
      path: /var/tempo/blocks  # Changed from /tmp/tempo/blocks

# Line 28-31: Increase retention to 14 days
compactor:
  compaction:
    compaction_window: 1h
    block_retention: 336h  # Changed from 1h to 14 days

# Line 52-53: Fix metrics generator WAL path
metrics_generator:
  storage:
    path: /var/tempo/generator/wal  # Changed from /tmp/tempo/generator/wal
```

#### 2. Fix Loki storage paths
**File:** `config/loki-config.yaml`

**Changes:**
```yaml
# Line 12-17: Align path_prefix with volume mount
common:
  path_prefix: /tmp/loki  # Changed from /loki to match volume
  storage:
    filesystem:
      chunks_directory: /tmp/loki/chunks
      rules_directory: /tmp/loki/rules

# Line 33-40: Update storage_config paths
storage_config:
  boltdb_shipper:
    active_index_directory: /tmp/loki/boltdb-shipper-active
    cache_location: /tmp/loki/boltdb-shipper-cache
  filesystem:
    directory: /tmp/loki/chunks

# Line 42-49: Update compactor paths
compactor:
  working_directory: /tmp/loki/compactor

# Line 101-111: Update ruler paths
ruler:
  rule_path: /tmp/loki/rules-temp
  storage:
    local:
      directory: /tmp/loki/rules
```

#### 3. Fix Mimir storage paths
**File:** `config/mimir-config.yaml`

**Changes:**
```yaml
# Line 10-14: Align common storage with volume mount
common:
  storage:
    backend: filesystem
    filesystem:
      dir: /tmp/mimir/common

# Line 16-22: Update blocks_storage paths and retention
blocks_storage:
  backend: filesystem
  filesystem:
    dir: /tmp/mimir/blocks
  tsdb:
    dir: /tmp/mimir/tsdb
    retention_period: 336h  # Increased from 168h to 14 days

# Line 45-46: Update alertmanager path
alertmanager:
  data_dir: /tmp/mimir/alertmanager

# Line 50-51: Update ruler path
ruler:
  rule_path: /tmp/mimir/rules

# Line 58-59: Update compactor path
compactor:
  data_dir: /tmp/mimir/compactor

# Line 62-65: Update ruler_storage path
ruler_storage:
  backend: filesystem
  filesystem:
    dir: /tmp/mimir/ruler-storage
```

### Phase 2: Add Loki Log Exporter

#### 4. Configure OTel Collector to send logs to Loki
**File:** `config/otel-collector-config.yaml`

**Changes:**
```yaml
# Add loki exporter in exporters section (after line 33)
exporters:
  # ... existing exporters ...

  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    default_labels_enabled:
      exporter: true
      job: true
    labels:
      attributes:
        service.name: "service_name"
        service.namespace: "service_namespace"
      resource:
        service.name: "service_name"
        service.instance.id: "instance_id"

# Update logs pipeline (line 48-50)
logs:
  receivers: [otlp]
  processors: [memory_limiter, batch]
  exporters: [loki]  # Changed from [debug]
```

### Phase 3: Reliability Improvements

#### 5. Add health checks to docker-compose
**File:** `docker-compose.yml`

**Changes:** Add healthcheck to each service:
```yaml
loki:
  # ... existing config ...
  healthcheck:
    test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3100/ready || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s

tempo:
  # ... existing config ...
  healthcheck:
    test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3200/ready || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s

mimir:
  # ... existing config ...
  healthcheck:
    test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:9009/ready || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s

grafana:
  # ... existing config ...
  healthcheck:
    test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:3000/api/health || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 30s

otel-collector:
  # ... existing config ...
  healthcheck:
    test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:13133/health || exit 1"]
    interval: 10s
    timeout: 5s
    retries: 5
    start_period: 15s
```

#### 6. Update service dependencies with health conditions
**File:** `docker-compose.yml`

**Changes:**
```yaml
tempo:
  depends_on:
    init:
      condition: service_completed_successfully
    loki:
      condition: service_healthy

grafana:
  depends_on:
    loki:
      condition: service_healthy
    tempo:
      condition: service_healthy
    mimir:
      condition: service_healthy

otel-collector:
  depends_on:
    loki:
      condition: service_healthy
    tempo:
      condition: service_healthy
    mimir:
      condition: service_healthy
```

#### 7. Pin image versions for reproducibility
**File:** `docker-compose.yml`

**Changes:** Replace `:latest` with specific versions:
```yaml
# Research current stable versions and pin them
grafana/loki:3.3.2        # or current stable
grafana/tempo:2.6.1       # or current stable
grafana/mimir:2.14.1      # or current stable
grafana/grafana:11.3.1    # or current stable
otel/opentelemetry-collector-contrib:0.114.0  # or current stable
```

#### 8. Add retry and queue config to OTel Collector exporters
**File:** `config/otel-collector-config.yaml`

**Changes:**
```yaml
exporters:
  otlphttp/tempo:
    endpoint: http://tempo:14318
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000

  prometheusremotewrite/mimir:
    endpoint: http://mimir:9009/api/v1/push
    headers:
      X-Scope-OrgID: "demo"
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000

  loki:
    endpoint: http://loki:3100/loki/api/v1/push
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 1000
```

#### 9. Add OTel Collector health extension
**File:** `config/otel-collector-config.yaml`

**Changes:**
```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133

service:
  extensions: [health_check]
  pipelines:
    # ... existing pipelines ...
```

### Phase 4: Verification

#### 10. Test stack after changes
- Bring down stack: `docker compose down`
- Clear old data: `sudo rm -rf ./data/*` (if using bind mounts) or `docker volume rm` for named volumes
- Bring up stack: `docker compose up -d`
- Wait for health checks to pass: `docker compose ps`
- Verify Grafana datasources connect
- Send test traces from instrumentation package
- Verify traces persist after 2+ hours

#### 11. Review implementation and capture key facts to memory
- Document final working configuration
- Note any issues encountered during implementation
- Store key learnings for future reference

---

## Questions

None - requirements are clear from the analysis.

---

## File Change Summary

| File | Changes |
|------|---------|
| `config/tempo-config.yaml` | Fix paths, increase retention to 336h |
| `config/loki-config.yaml` | Align paths with volume mount |
| `config/mimir-config.yaml` | Align paths with volume mount, increase retention |
| `config/otel-collector-config.yaml` | Add Loki exporter, health extension, retry configs |
| `docker-compose.yml` | Add health checks, pin versions, update depends_on |

---

## Rollback Plan

If issues occur:
1. Keep backup of current configs before changes
2. `docker compose down`
3. Restore original configs from backup
4. `docker compose up -d`

---

## Compatibility Notes

- **@your-org/instrumentation:** No breaking changes - OTLP HTTP on 4318 preserved
- **Grafana datasources:** No changes needed - internal URLs unchanged
- **Service names:** No changes to container names or network

---

## Implementation Notes (2025-11-28)

### Deviations from Original Plan

1. **Loki Exporter Changed to OTLP HTTP**
   - Original: Use deprecated `loki` exporter
   - Implemented: Use `otlphttp/loki` to Loki's native OTLP endpoint (`/otlp`)
   - Reason: Loki exporter is deprecated in OTel Collector; Loki 3.0+ supports native OTLP ingestion

2. **Loki Schema Updated to v13 with TSDB**
   - Original: Keep schema v11 with boltdb-shipper
   - Implemented: Upgrade to schema v13 with tsdb
   - Reason: Required for `allow_structured_metadata: true` which is needed for OTLP log ingestion

3. **Mimir Health Check Removed**
   - Original: Add wget-based health check
   - Implemented: No health check (use `service_started` condition)
   - Reason: Mimir uses distroless image without wget/curl; health endpoint still works but can't be checked internally

4. **Added init-loki Service**
   - Not in original plan
   - Added to fix volume permissions for Loki (runs as user 10001, same as Tempo)

5. **Removed sending_queue from prometheusremotewrite**
   - Original: Include sending_queue config
   - Implemented: Removed (not a valid config key)

### Final Image Versions

- grafana/loki:3.3.2
- grafana/tempo:2.6.1
- grafana/mimir:2.14.1
- grafana/grafana:11.3.1
- otel/opentelemetry-collector-contrib:0.114.0

### Verification Results

All services started successfully with health checks passing:
- Loki: healthy (/ready)
- Tempo: healthy (/ready)
- Mimir: ready (after ~15s stabilization)
- Grafana: healthy (/api/health)
- OTel Collector: healthy (/)
