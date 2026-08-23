# Volume Management in Docker Compose

**Purpose**: Guide for managing volumes, data persistence, and volume permissions in Docker Compose.

---

## Overview

Docker volumes provide persistent data storage for containers. In the LGTM stack, volumes store:
- **Loki**: Log index and chunks
- **Tempo**: Trace data and WAL (Write-Ahead Log)
- **Mimir**: Metrics data
- **Grafana**: Dashboards, datasources, and configuration

Without volumes, all data is lost when containers are removed.

---

## Volume Types

### 1. Named Volumes (Recommended for Production)

Docker manages the volume location. Data persists across container restarts and removals.

```yaml
services:
  loki:
    image: grafana/loki:latest
    volumes:
      - loki-data:/tmp/loki

volumes:
  loki-data: {}  # Docker manages this volume
```

**Location**: Typically `/var/lib/docker/volumes/<project>_<volume-name>/_data`

**Pros**:
- Docker manages lifecycle
- Portable across environments
- Easy backup with `docker volume` commands
- Proper permissions handling

**Cons**:
- Harder to access from host
- Opaque location

---

### 2. Bind Mounts (Development/Testing)

Mount a host directory directly into the container.

```yaml
services:
  loki:
    image: grafana/loki:latest
    volumes:
      - ./data/loki:/tmp/loki

# No top-level volumes declaration needed
```

**Pros**:
- Easy access from host
- Simple backup (copy directory)
- Can edit configuration files directly

**Cons**:
- Permission issues common
- Not portable (absolute paths)
- Host filesystem performance

---

### 3. Anonymous Volumes

Docker creates a volume with a random name.

```yaml
services:
  loki:
    image: grafana/loki:latest
    volumes:
      - /tmp/loki  # No named source
```

**Pros**:
- Quick for testing

**Cons**:
- Hard to identify
- Not reused between containers
- Removed with `docker compose down -v`

---

## LGTM Stack Volume Configuration

### Current Configuration

From `docker-compose.yml`:

```yaml
volumes:
  loki-data: {}
  tempo-data: {}
  mimir-data: {}
  grafana-data: {}

services:
  loki:
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml
      - loki-data:/tmp/loki

  tempo:
    volumes:
      - ./config/tempo-config.yaml:/etc/tempo/config.yaml
      - tempo-data:/var/tempo

  mimir:
    volumes:
      - ./config/mimir-config.yaml:/etc/mimir/config.yaml
      - mimir-data:/tmp/mimir

  grafana:
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana/provisioning/:/etc/grafana/provisioning/
```

**Mix of volume types**:
- **Named volumes**: For data persistence (loki-data, tempo-data, etc.)
- **Bind mounts**: For configuration files (./config/...)

---

### Switching to Bind Mounts (Optional)

The commented-out section shows bind mount configuration:

```yaml
volumes:
  loki-data:
    driver_opts:
      type: none
      device: ${PWD}/data/loki  # Host directory
      o: bind

  tempo-data:
    driver_opts:
      type: none
      device: ${PWD}/data/tempo
      o: bind

  # Similar for mimir-data and grafana-data
```

**When to use this**:
- Local development where you want direct file access
- Debugging data issues
- Custom backup scripts accessing raw files

**Prerequisites**:
```bash
# Create directories first
mkdir -p ./data/loki ./data/tempo ./data/mimir ./data/grafana
```

---

## Volume Permissions

### The Tempo Permission Problem

From the init container:

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
    depends_on:
      - init
    volumes:
      - tempo-data:/var/tempo
```

**Why this is needed**:
1. Docker creates volumes owned by `root:root` (UID 0)
2. Tempo container runs as user `10001` (non-root)
3. Tempo can't write to `/var/tempo` without ownership change
4. Init container runs as `root` to fix permissions

**Error without init container**:
```
Error: opening storage failed: mkdir /var/tempo/wal: permission denied
```

---

### Common UID/GID Patterns

| Service | User | UID | Why |
|---------|------|-----|-----|
| Tempo | tempo | 10001 | Security (non-root) |
| Loki | loki | 10001 | Security (non-root) |
| Grafana | grafana | 472 | Security (non-root) |
| Mimir | mimir | 10001 | Security (non-root) |

**Check container user**:
```bash
docker compose exec loki id
# Output: uid=10001(loki) gid=10001(loki) groups=10001(loki)
```

---

### Solutions for Permission Issues

#### Option 1: Init Container (Current Approach)

**Pros**:
- Clean separation of concerns
- One-time setup
- Works with named volumes

**Cons**:
- Extra container
- Slightly more complex

**Pattern**:
```yaml
init-tempo:
  image: grafana/tempo:latest
  user: root
  entrypoint: ["chown", "-R", "10001:10001", "/var/tempo"]
  volumes:
    - tempo-data:/var/tempo

tempo:
  depends_on:
    init-tempo:
      condition: service_completed_successfully
```

---

#### Option 2: User Directive

Run service as root (NOT recommended for production):

```yaml
tempo:
  image: grafana/tempo:latest
  user: root  # Run as root
  volumes:
    - tempo-data:/var/tempo
```

**Pros**:
- Simple
- No init container

**Cons**:
- Security risk
- Not production-safe
- Violates least privilege principle

---

#### Option 3: Host Directory with Pre-set Permissions

Use bind mount with correct ownership:

```bash
# On host
mkdir -p ./data/tempo
sudo chown -R 10001:10001 ./data/tempo
```

```yaml
services:
  tempo:
    volumes:
      - ./data/tempo:/var/tempo
```

**Pros**:
- No init container
- Direct host access

**Cons**:
- Manual setup required
- Not portable (host-specific)
- Requires sudo on host

---

#### Option 4: volume-nocopy and Dockerfile

Build custom image that creates directories with correct ownership:

**Dockerfile**:
```dockerfile
FROM grafana/tempo:latest
USER root
RUN mkdir -p /var/tempo && chown -R 10001:10001 /var/tempo
USER 10001
```

**docker-compose.yml**:
```yaml
tempo:
  build: ./tempo-custom
  volumes:
    - tempo-data:/var/tempo:volume-nocopy
```

---

## Volume Options

### Read-Only Volumes

Configuration files should be read-only:

```yaml
services:
  loki:
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml:ro  # Read-only
      - loki-data:/tmp/loki  # Read-write
```

**Benefits**:
- Prevents accidental config changes
- Security best practice
- Clearer intent

---

### volume-nocopy

Prevents Docker from copying container data into empty volumes:

```yaml
services:
  grafana:
    volumes:
      - grafana-data:/var/lib/grafana:volume-nocopy
```

**When to use**:
- Custom images with pre-created directory structure
- Avoiding unwanted default file copies

**Default behavior** (without volume-nocopy):
```
1. Volume is empty
2. Container has files at /var/lib/grafana
3. Docker copies container files → volume
4. Container uses volume
```

---

### Volume Drivers

Default: `local` (host filesystem)

```yaml
volumes:
  loki-data:
    driver: local
```

**Other drivers**:
- `nfs`: Network File System
- `cifs`: Windows/Samba shares
- Third-party: GlusterFS, Ceph, etc.

**NFS Example**:
```yaml
volumes:
  loki-data:
    driver: local
    driver_opts:
      type: nfs
      o: addr=10.0.0.10,rw
      device: ":/path/to/dir"
```

---

## Volume Management Commands

### List Volumes
```bash
docker volume ls
```

### Inspect Volume
```bash
docker volume inspect lgtm-stack-experiment_loki-data
```

**Output**:
```json
[
  {
    "CreatedAt": "2025-11-28T10:30:00Z",
    "Driver": "local",
    "Mountpoint": "/var/lib/docker/volumes/lgtm-stack-experiment_loki-data/_data",
    "Name": "lgtm-stack-experiment_loki-data",
    "Scope": "local"
  }
]
```

### Access Volume Data (Linux)
```bash
# As root
sudo ls -la /var/lib/docker/volumes/lgtm-stack-experiment_loki-data/_data
```

### Create Volume Manually
```bash
docker volume create loki-data
```

### Remove Volumes
```bash
# Remove specific volume (must stop containers first)
docker compose down
docker volume rm lgtm-stack-experiment_loki-data

# Remove all project volumes
docker compose down -v

# Remove all unused volumes
docker volume prune
```

---

## Backup and Restore

### Backup Named Volume

**Method 1: Use temporary container**
```bash
# Backup Loki data
docker run --rm \
  -v lgtm-stack-experiment_loki-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/loki-backup.tar.gz -C /data .
```

**Method 2: Stop service and copy**
```bash
docker compose stop loki
sudo tar czf loki-backup.tar.gz \
  -C /var/lib/docker/volumes/lgtm-stack-experiment_loki-data/_data .
docker compose start loki
```

---

### Restore Named Volume

```bash
# Stop service
docker compose stop loki

# Restore from backup
docker run --rm \
  -v lgtm-stack-experiment_loki-data:/data \
  -v $(pwd):/backup \
  alpine sh -c "cd /data && tar xzf /backup/loki-backup.tar.gz"

# Start service
docker compose start loki
```

---

### Backup Bind Mount

Simple directory copy:
```bash
# Backup
tar czf lgtm-backup.tar.gz ./data/

# Restore
tar xzf lgtm-backup.tar.gz
```

---

## Complete LGTM Stack Volume Configuration

### Production-Ready (Named Volumes)

```yaml
volumes:
  loki-data: {}
  tempo-data: {}
  mimir-data: {}
  grafana-data: {}

services:
  init:
    image: grafana/tempo:latest
    user: root
    entrypoint: ["chown", "10001:10001", "/var/tempo"]
    volumes:
      - tempo-data:/var/tempo

  loki:
    image: grafana/loki:latest
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml:ro
      - loki-data:/tmp/loki

  tempo:
    image: grafana/tempo:latest
    depends_on:
      init:
        condition: service_completed_successfully
    volumes:
      - ./config/tempo-config.yaml:/etc/tempo/config.yaml:ro
      - tempo-data:/var/tempo

  mimir:
    image: grafana/mimir:latest
    volumes:
      - ./config/mimir-config.yaml:/etc/mimir/config.yaml:ro
      - mimir-data:/tmp/mimir

  grafana:
    image: grafana/grafana:latest
    volumes:
      - grafana-data:/var/lib/grafana
      - ./config/grafana/provisioning/:/etc/grafana/provisioning/:ro
```

---

### Development (Bind Mounts)

```yaml
services:
  loki:
    image: grafana/loki:latest
    volumes:
      - ./config/loki-config.yaml:/etc/loki/config.yaml:ro
      - ./data/loki:/tmp/loki

  tempo:
    image: grafana/tempo:latest
    user: "10001:10001"  # Match Tempo user
    volumes:
      - ./config/tempo-config.yaml:/etc/tempo/config.yaml:ro
      - ./data/tempo:/var/tempo

  mimir:
    image: grafana/mimir:latest
    volumes:
      - ./config/mimir-config.yaml:/etc/mimir/config.yaml:ro
      - ./data/mimir:/tmp/mimir

  grafana:
    image: grafana/grafana:latest
    user: "472:472"  # Match Grafana user
    volumes:
      - ./data/grafana:/var/lib/grafana
      - ./config/grafana/provisioning/:/etc/grafana/provisioning/:ro

# No top-level volumes needed for bind mounts
```

**Setup script**:
```bash
#!/bin/bash
mkdir -p ./data/{loki,tempo,mimir,grafana}
sudo chown -R 10001:10001 ./data/loki ./data/tempo ./data/mimir
sudo chown -R 472:472 ./data/grafana
```

---

## Best Practices

1. **Use named volumes for production** - Docker manages lifecycle and permissions
2. **Use bind mounts for configuration** - Easy to edit and version control
3. **Always mark config files as read-only** - Prevent accidental changes
4. **Handle permissions explicitly** - Use init containers or pre-setup
5. **Backup volumes regularly** - Data loss without backups
6. **Use `.dockerignore`** - Don't copy `data/` into images
7. **Document volume purposes** - Comments in docker-compose.yml
8. **Test restore procedures** - Backups are useless if restore doesn't work

---

## Troubleshooting

### Permission Denied Errors

**Symptom**:
```
Error: opening storage failed: mkdir /var/tempo/wal: permission denied
```

**Solution**:
1. Add init container to fix permissions
2. Or run container as root (not recommended)
3. Or pre-setup host directory permissions

---

### Volume Already Exists

**Symptom**:
```
Error: volume name already in use
```

**Solution**:
```bash
# Remove old volume
docker compose down
docker volume rm lgtm-stack-experiment_loki-data

# Recreate
docker compose up -d
```

---

### Disk Space Issues

**Check volume sizes**:
```bash
docker system df -v
```

**Clean up**:
```bash
# Remove unused volumes
docker volume prune

# Remove all project data
docker compose down -v
```

---

## References

- Docker volumes: https://docs.docker.com/storage/volumes/
- Docker Compose volumes: https://docs.docker.com/compose/compose-file/05-services/#volumes
- Volume permissions: https://docs.docker.com/storage/volumes/#use-a-volume-with-docker-compose
