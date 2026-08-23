# Networking in Docker Compose

**Purpose**: Guide for Docker Compose networking, service discovery, port mapping, and network configuration.

---

## Overview

Docker Compose creates a default network for services to communicate. In the LGTM stack:
- **Internal communication**: Services talk via service names (loki, tempo, mimir)
- **External access**: Ports are published to host (3000, 3100, 3200, 9009, 4317, 4318)
- **Network isolation**: Services only accessible within the network (unless ports are published)

---

## Default Network Behavior

### Automatic Network Creation

When you run `docker compose up`, Compose automatically creates a network:

```bash
# Project name: lgtm-stack-experiment
# Network name: lgtm-stack-experiment_default
```

**All services join this network automatically** unless you specify otherwise.

---

### Service Discovery (DNS)

Containers can reach each other using service names:

```yaml
services:
  grafana:
    image: grafana/grafana:latest

  loki:
    image: grafana/loki:latest
```

**Inside grafana container**:
```bash
# These all work:
curl http://loki:3100/ready
ping loki
nslookup loki
```

**How it works**:
1. Docker has an embedded DNS server (127.0.0.11)
2. Service name → Container IP resolution
3. Automatic updates when containers restart

---

## Custom Networks

### Defining Networks

From `docker-compose.yml`:

```yaml
networks:
  lgtm-net:
    driver: bridge

services:
  loki:
    networks:
      - lgtm-net

  tempo:
    networks:
      - lgtm-net

  grafana:
    networks:
      - lgtm-net
```

**Why use custom networks**:
1. **Explicit naming**: "lgtm-net" vs "lgtm-stack-experiment_default"
2. **Multiple networks**: Isolate services into groups
3. **Network options**: Configure driver options
4. **Documentation**: Clearer intent

---

### Network Drivers

| Driver | Description | Use Case |
|--------|-------------|----------|
| `bridge` | Default, single-host networking | **LGTM stack (recommended)** |
| `host` | No network isolation, use host network | Performance-critical, debugging |
| `none` | No networking | Isolation, batch jobs |
| `overlay` | Multi-host networking | Docker Swarm, Kubernetes |
| `macvlan` | Assign MAC address to container | Legacy app integration |

**LGTM Stack**: Use `bridge` driver (default)

```yaml
networks:
  lgtm-net:
    driver: bridge
```

---

### Bridge Network (Default)

Bridge networks provide:
- **Isolation**: Containers on different networks can't communicate
- **Service discovery**: DNS-based service name resolution
- **Port mapping**: Publish ports to host
- **Gateway**: Containers can reach internet

**Network Details**:
```bash
docker network inspect lgtm-stack-experiment_lgtm-net
```

**Output**:
```json
{
  "Name": "lgtm-stack-experiment_lgtm-net",
  "Driver": "bridge",
  "Subnet": "172.18.0.0/16",
  "Gateway": "172.18.0.1",
  "Containers": {
    "loki": {
      "IPv4Address": "172.18.0.2/16"
    },
    "tempo": {
      "IPv4Address": "172.18.0.3/16"
    }
  }
}
```

---

## Port Mapping

### Publishing Ports to Host

```yaml
services:
  grafana:
    ports:
      - "3000:3000"  # HOST:CONTAINER
```

**Format**: `"[HOST_IP:]HOST_PORT:CONTAINER_PORT[/PROTOCOL]"`

---

### Port Mapping Examples

```yaml
services:
  grafana:
    ports:
      # Basic mapping
      - "3000:3000"              # localhost:3000 → container:3000

      # Bind to specific IP
      - "127.0.0.1:3000:3000"    # Only accessible on localhost

      # Different host and container ports
      - "8080:3000"              # localhost:8080 → container:3000

      # Port range
      - "8080-8085:3000-3005"    # Maps 6 ports

      # UDP protocol
      - "4317:4317/udp"          # UDP instead of TCP

      # IPv6
      - "[::1]:3000:3000"        # IPv6 localhost
```

---

### LGTM Stack Port Configuration

From `docker-compose.yml`:

```yaml
services:
  loki:
    ports:
      - "3100:3100"  # Loki HTTP API
      - "9096:9096"  # Loki gRPC (optional)

  tempo:
    ports:
      - "3200:3200"  # Tempo HTTP API

  mimir:
    ports:
      - "9009:9009"  # Mimir HTTP API
      - "9095:9095"  # Mimir gRPC (optional)

  grafana:
    ports:
      - "3000:3000"  # Grafana UI

  otel-collector:
    ports:
      - "4317:4317"  # OTLP gRPC receiver
      - "4318:4318"  # OTLP HTTP receiver
```

**Port Summary**:
| Port | Service | Protocol | Purpose |
|------|---------|----------|---------|
| 3000 | Grafana | HTTP | Web UI |
| 3100 | Loki | HTTP | Log ingestion/queries |
| 3200 | Tempo | HTTP | Trace ingestion/queries |
| 9009 | Mimir | HTTP | Metrics ingestion/queries |
| 4317 | OTel Collector | gRPC | OTLP receiver |
| 4318 | OTel Collector | HTTP | OTLP receiver |

---

### Internal vs External Ports

**Internal only** (no `ports:` mapping):
```yaml
services:
  backend:
    image: mybackend
    # No ports section
    # Only accessible from other containers via service name
```

**External and internal** (with `ports:` mapping):
```yaml
services:
  grafana:
    ports:
      - "3000:3000"
    # Accessible from:
    # - Other containers: http://grafana:3000
    # - Host: http://localhost:3000
    # - External: http://HOST_IP:3000
```

---

### Expose vs Ports

```yaml
services:
  loki:
    expose:
      - "3100"  # Document port, doesn't publish to host

    ports:
      - "3100:3100"  # Publish to host
```

**`expose`**:
- Documents which ports the service uses
- Doesn't publish to host
- Useful for inter-service communication only

**`ports`**:
- Publishes to host
- Accessible externally
- **Use this for LGTM stack services**

---

## Multi-Network Configuration

### Isolating Services

```yaml
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
  monitoring:
    driver: bridge

services:
  # Web frontend - only on frontend network
  web:
    networks:
      - frontend

  # API - on frontend and backend networks
  api:
    networks:
      - frontend
      - backend

  # Database - only on backend network
  db:
    networks:
      - backend

  # LGTM stack - on monitoring network
  grafana:
    networks:
      - frontend      # Access to frontend for metrics
      - monitoring    # LGTM internal communication

  loki:
    networks:
      - monitoring

  tempo:
    networks:
      - monitoring

  mimir:
    networks:
      - monitoring
```

**Result**:
- `web` can talk to `api`
- `api` can talk to `web` and `db`
- `db` can only talk to `api` (isolated from `web`)
- LGTM services can all talk to each other

---

### Network Aliases

Give services alternative hostnames:

```yaml
services:
  loki:
    networks:
      lgtm-net:
        aliases:
          - logs
          - log-aggregator
```

**Access methods**:
```bash
curl http://loki:3100/ready
curl http://logs:3100/ready
curl http://log-aggregator:3100/ready
```

---

## Network Configuration Options

### IPv4 and IPv6 Addresses

Assign static IPs to containers:

```yaml
networks:
  lgtm-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
          gateway: 172.28.0.1

services:
  loki:
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.10

  tempo:
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.11

  mimir:
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.12
```

**When to use static IPs**:
- Integration with external systems requiring specific IPs
- Firewall rules based on IP
- Debugging network issues

**Recommendation**: Use service names instead (more flexible)

---

### IPAM (IP Address Management)

Configure subnet, gateway, and IP range:

```yaml
networks:
  lgtm-net:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/16
          gateway: 172.28.0.1
          ip_range: 172.28.5.0/24
```

**Options**:
- `subnet`: Network subnet (CIDR notation)
- `gateway`: Default gateway
- `ip_range`: Range for automatic IP assignment

---

### Driver Options

Configure bridge network behavior:

```yaml
networks:
  lgtm-net:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: lgtm-br0
      com.docker.network.bridge.host_binding_ipv4: "127.0.0.1"
      com.docker.network.driver.mtu: 1450
```

**Common options**:
| Option | Description | Example |
|--------|-------------|---------|
| `com.docker.network.bridge.name` | Bridge interface name | `lgtm-br0` |
| `com.docker.network.bridge.host_binding_ipv4` | Bind published ports to IP | `127.0.0.1` |
| `com.docker.network.driver.mtu` | Maximum Transmission Unit | `1450` |
| `com.docker.network.bridge.enable_icc` | Inter-container communication | `true` |

---

### External Networks

Connect to pre-existing networks:

```yaml
networks:
  existing-network:
    external: true
    name: my-pre-existing-network

services:
  grafana:
    networks:
      - existing-network
```

**Use case**: Connect LGTM stack to existing application network

---

## Service-Level Network Options

### MAC Address

Assign custom MAC address:

```yaml
services:
  loki:
    networks:
      lgtm-net:
        mac_address: 02:42:ac:11:00:02
```

**When to use**: Legacy applications expecting specific MAC

---

### Priority and Gateway Priority

Control network selection for multi-network services:

```yaml
services:
  grafana:
    networks:
      frontend:
        priority: 1000     # Connect first
        gw_priority: 1     # Use as default gateway
      monitoring:
        priority: 100
        gw_priority: 0
```

**priority**: Connection order (higher = first)
**gw_priority**: Default gateway selection (higher = default)

---

### Link-Local IPs

Assign link-local IP addresses:

```yaml
services:
  loki:
    networks:
      lgtm-net:
        link_local_ips:
          - 169.254.1.10
```

**Use case**: Special networking requirements (rare)

---

## Complete LGTM Network Configuration

### Basic Configuration (Recommended)

```yaml
networks:
  lgtm-net:
    driver: bridge

services:
  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    networks:
      - lgtm-net

  tempo:
    image: grafana/tempo:latest
    container_name: tempo
    ports:
      - "3200:3200"
    networks:
      - lgtm-net

  mimir:
    image: grafana/mimir:latest
    container_name: mimir
    ports:
      - "9009:9009"
    networks:
      - lgtm-net

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    networks:
      - lgtm-net

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: otel-collector
    ports:
      - "4317:4317"
      - "4318:4318"
    networks:
      - lgtm-net
```

---

### Advanced Configuration

```yaml
networks:
  lgtm-net:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.name: lgtm-br0
      com.docker.network.bridge.enable_icc: "true"
      com.docker.network.driver.mtu: 1450
    ipam:
      driver: default
      config:
        - subnet: 172.28.0.0/16
          gateway: 172.28.0.1

services:
  loki:
    image: grafana/loki:latest
    ports:
      - "127.0.0.1:3100:3100"  # Only localhost access
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.10
        aliases:
          - logs

  tempo:
    image: grafana/tempo:latest
    ports:
      - "127.0.0.1:3200:3200"
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.11
        aliases:
          - traces

  mimir:
    image: grafana/mimir:latest
    ports:
      - "127.0.0.1:9009:9009"
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.12
        aliases:
          - metrics

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"  # Public access
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.20

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    ports:
      - "4317:4317"
      - "4318:4318"
    networks:
      lgtm-net:
        ipv4_address: 172.28.0.30
        aliases:
          - otel
```

---

## Network Security

### Bind to Localhost Only

Prevent external access:

```yaml
services:
  loki:
    ports:
      - "127.0.0.1:3100:3100"  # Only localhost
```

**Result**: Service only accessible from host, not from external network

---

### Disable Inter-Container Communication

Isolate containers on same network:

```yaml
networks:
  isolated:
    driver: bridge
    driver_opts:
      com.docker.network.bridge.enable_icc: "false"
```

**Note**: Breaks most LGTM communication, not recommended

---

## Network Troubleshooting

### Check Network Configuration

```bash
# List networks
docker network ls

# Inspect network
docker network inspect lgtm-stack-experiment_lgtm-net

# Check container network
docker inspect loki | grep -A 20 Networks
```

---

### Test Service Discovery

```bash
# From within container
docker compose exec grafana sh

# Inside container
ping loki
curl http://loki:3100/ready
nslookup loki
```

---

### Test Port Accessibility

```bash
# From host
curl http://localhost:3100/ready  # Loki
curl http://localhost:3200/ready  # Tempo
curl http://localhost:9009/ready  # Mimir
curl http://localhost:3000/api/health  # Grafana
```

---

### Common Network Issues

**Can't connect to service by name**:
```bash
# Check if services are on same network
docker network inspect lgtm-stack-experiment_lgtm-net
```

**Port already in use**:
```bash
# Find what's using the port
sudo lsof -i :3000

# Change host port
ports:
  - "3001:3000"  # Use 3001 on host
```

**Can't access from host**:
```bash
# Verify port is published
docker compose ps

# Check firewall
sudo ufw status

# Check if binding to correct interface
netstat -tlnp | grep 3000
```

---

## Best Practices

1. **Use custom network names** - Better than default for documentation
2. **Use service names for internal communication** - Don't use IPs
3. **Bind sensitive services to localhost** - `127.0.0.1:PORT:PORT`
4. **Document network topology** - Comments in docker-compose.yml
5. **Use bridge driver** - Default is fine for single-host deployments
6. **Avoid static IPs unless necessary** - Service names are more flexible
7. **Test connectivity** - Use `docker compose exec` to verify
8. **Use DNS aliases sparingly** - Service names are usually sufficient

---

## LGTM Stack Network Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                         Host Network                         │
│                                                               │
│  localhost:3000  ──→  Grafana UI                            │
│  localhost:3100  ──→  Loki API                              │
│  localhost:3200  ──→  Tempo API                             │
│  localhost:9009  ──→  Mimir API                             │
│  localhost:4317  ──→  OTel Collector (gRPC)                 │
│  localhost:4318  ──→  OTel Collector (HTTP)                 │
│                                                               │
└────────────────────────────┬──────────────────────────────────┘
                             │
                             │ Port Publishing
                             │
┌────────────────────────────┴──────────────────────────────────┐
│                      lgtm-net (bridge)                        │
│                   Subnet: 172.18.0.0/16                       │
│                                                               │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────┐    │
│  │ Grafana │  │  Loki   │  │  Tempo  │  │    Mimir    │    │
│  │  :3000  │──│  :3100  │──│  :3200  │──│    :9009    │    │
│  └─────────┘  └─────────┘  └─────────┘  └─────────────┘    │
│       │            │            │                │            │
│       └────────────┴────────────┴────────────────┘            │
│                           │                                   │
│                    ┌──────┴───────┐                          │
│                    │ OTel Collect │                          │
│                    │ :4317, :4318 │                          │
│                    └──────────────┘                          │
│                                                               │
│  Service Discovery: All services accessible by name          │
│  grafana → http://loki:3100                                 │
│  otel-collector → http://tempo:3200                         │
└───────────────────────────────────────────────────────────────┘
```

---

## References

- Docker Compose networking: https://docs.docker.com/compose/networking/
- Docker Compose networks: https://docs.docker.com/compose/compose-file/06-networks/
- Docker bridge networks: https://docs.docker.com/network/bridge/
- Service discovery: https://docs.docker.com/compose/networking/#use-a-pre-existing-network
