# LGTM Backends Configuration Agent

## Purpose

Research specialist for Loki, Tempo, and Mimir backend configuration optimization, troubleshooting, and best practices.

## Scope

- **Loki**: Log aggregation configuration - storage, retention, ingestion limits, query performance
- **Tempo**: Distributed tracing configuration - block storage, compaction, search, metrics generator
- **Mimir**: Metrics backend configuration - series limits, compaction, query frontend, multi-tenancy

## Documentation

### Research Outputs (docs/)
Research findings will be stored here as the agent is used:
- `loki-storage-optimization-YYYY-MM-DD.md`
- `tempo-retention-config-YYYY-MM-DD.md`
- `mimir-series-limits-YYYY-MM-DD.md`

### Task Plans (tasks/)
PRDs and implementation plans for configuration changes.

### Standard Procedures (sops/)
How-to guides for common configuration tasks:
- Adjusting retention policies
- Tuning ingestion limits
- Optimizing query performance
- Migrating storage backends

## Usage

Invoke this agent when you need to research:

1. **Storage Configuration**
   - "What's the best storage backend for local development?"
   - "How should I configure Tempo block storage?"
   - "What retention settings are appropriate for each backend?"

2. **Performance Tuning**
   - "Why is Loki query slow?"
   - "How can I optimize Tempo compaction?"
   - "What Mimir settings affect query performance?"

3. **Troubleshooting**
   - "Loki is running out of disk space"
   - "Tempo traces aren't being ingested"
   - "Mimir is rejecting samples"

4. **Production Readiness**
   - "What configuration changes are needed for production?"
   - "How do local dev settings differ from production?"
   - "What scaling considerations exist?"

## Related Agents

- **otel-collector-architecture-agent** - For OTel Collector pipeline configuration (receivers, processors, exporters)
- Use this agent for backend-specific configuration; use otel-collector agent for data flow configuration

## Key Configuration Files

| File | Purpose |
|------|---------|
| `config/loki-config.yaml` | Loki backend configuration |
| `config/tempo-config.yaml` | Tempo tracing backend configuration |
| `config/mimir-config.yaml` | Mimir metrics backend configuration |
| `config/otel-collector-config.yaml` | OTel Collector (exports to backends) |

## References

- [Loki Configuration](https://grafana.com/docs/loki/latest/configure/)
- [Tempo Configuration](https://grafana.com/docs/tempo/latest/configuration/)
- [Mimir Configuration](https://grafana.com/docs/mimir/latest/configure/)
