# LGTM Configuration Compatibility Agent

## Purpose

Research configuration compatibility, track deprecated options, and identify breaking changes across the LGTM observability stack to prevent stack disruptions from outdated or incompatible configurations.

## Scope

This agent covers configuration compatibility for:
- **Loki** - Log aggregation configuration
- **Tempo** - Distributed tracing configuration
- **Mimir** - Metrics backend configuration
- **Grafana** - Visualization and datasource configuration
- **OTel Collector** - Pipeline and exporter configuration

## Documentation

### Research Outputs (docs/)
- `compatibility-{component}-{YYYY-MM-DD}.md` - Per-component compatibility reports
- `full-stack-audit-{YYYY-MM-DD}.md` - Full stack compatibility audits
- `deprecation-inventory.md` - Running inventory of deprecated options

### Task Plans (tasks/)
- PRDs and migration plans for version upgrades

### Standard Procedures (sops/)
- `pre-upgrade-checklist.md` - Steps before upgrading any component
- `compatibility-check-process.md` - How to validate configuration compatibility

## Usage

Invoke this agent when you need to:
- **Check if current configurations are compatible** with newer versions
- **Identify deprecated options** before they cause failures
- **Plan version upgrades** with awareness of breaking changes
- **Audit configuration files** against current documentation
- **Understand migration paths** for deprecated settings

## Example Invocations

```
"Check if our Loki configuration is compatible with the latest version"
"What deprecated options are we using in the OTel Collector config?"
"Research breaking changes between Tempo 2.3 and 2.5"
"Audit all LGTM configurations for deprecated settings"
"What migration steps are needed to upgrade Mimir?"
```

## Key Resources

| Component | Config File | Documentation |
|-----------|-------------|---------------|
| Loki | `config/loki-config.yaml` | https://grafana.com/docs/loki/latest/configure/ |
| Tempo | `config/tempo-config.yaml` | https://grafana.com/docs/tempo/latest/configuration/ |
| Mimir | `config/mimir-config.yaml` | https://grafana.com/docs/mimir/latest/configure/ |
| Grafana | `config/grafana/` | https://grafana.com/docs/grafana/latest/ |
| OTel Collector | `config/otel-collector-config.yaml` | https://opentelemetry.io/docs/collector/ |

## Related Agents

- **lgtm-backends-config-agent** - For performance tuning and optimization (not compatibility)
- **otel-collector-architecture-agent** - For pipeline architecture decisions
- **docker-compose-orchestration-agent** - For container/service orchestration
