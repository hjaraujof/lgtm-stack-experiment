# LGTM Alert Runbooks

Each alert rule's `runbook_url` annotation points at a file here. The Alertmanager renders the link
into the notification, so a responder gets the runbook path with the alert.

These are first-response guides, not full incident procedures.

| Alert | Runbook | Severity |
|---|---|---|
| HighServiceErrorRatio, ServiceErrorBudgetFastBurn/SlowBurn, ServiceAvailabilitySLIUnmeasurable | [service-error-budget.md](service-error-budget.md) | warn/crit |
| EndpointTotallyFailing | [endpoint-total-failure.md](endpoint-total-failure.md) | critical |
| ServiceAuthFailureRateHigh | [service-auth-failures.md](service-auth-failures.md) | warning |
| ServiceLatencySLIBreach | [service-latency.md](service-latency.md) | warning |
| ServiceTelemetrySilent | [service-absent.md](service-absent.md) | warning |
| SpanMetricsPipelineSilent, ProdSpanMetricsPipelineSilent, both ImplausiblyLow, ApplicationMetricsAbsent | [pipeline-silent.md](pipeline-silent.md) | crit/warn |
| TempoLiveTracesExceeded, TempoLiveTracesHigh | [tempo-live-traces.md](tempo-live-traces.md) | crit/warn |
| TempoTraceTooLarge, TempoSpansDiscardedUnknownReason | [tempo-trace-too-large.md](tempo-trace-too-large.md) | crit/warn |
| TempoCompactionStalled | [tempo-compaction.md](tempo-compaction.md) | warning |
| MimirSamplesDiscarded, MimirDuplicateOrOutOfOrderSamples, SpanMetricsFlushApproachingBurstLimit | [mimir-discards.md](mimir-discards.md) | warning |
| MimirBlockUploadOrCompactionFailing | [mimir-block-failure.md](mimir-block-failure.md) | critical |
| MimirActiveSeriesHigh | [mimir-cardinality.md](mimir-cardinality.md) | warning |
| CollectorTailSamplingDroppingTraces | [collector-tail-sampling.md](collector-tail-sampling.md) | critical |
| CollectorExportFailing, CollectorQueueSaturated | [collector-export.md](collector-export.md) | crit/warn |
| LokiSamplesDiscarded, LokiTenantFakeIngest | [loki-discards.md](loki-discards.md) | warning |
| AlertDeliverySilent, AlertmanagerConfigChanged, Watchdog | [alert-delivery-silent.md](alert-delivery-silent.md) | crit/warn |

Not alert-driven, but kept here:

| Task | Runbook |
|---|---|
| Create the GitHub OIDC role that publishes the boot archive | [bootstrap-publish-role.md](bootstrap-publish-role.md) |

**Common context:** a single host running docker compose. Grafana at the configured domain, with
Loki, Tempo and Mimir datasources. The stack is CPU-bound, not RAM-bound.

## The four lessons these runbooks keep repeating

They are worth reading even when nothing is firing, because each one describes a way a monitoring
stack lies to you rather than a way a service fails.

1. **Never read silence as health.** A quiet notification channel can mean the alert path is dead.
   Only an OUT-OF-BAND detector can tell the two apart. See
   [alert-delivery-silent.md](alert-delivery-silent.md).
2. **A trickle defeats an equality test.** A `== 0` detector cannot see a pipeline that is 99.8%
   dead. Pair every `== 0` with a floor. See [pipeline-silent.md](pipeline-silent.md).
3. **An empty selector is not a zero.** `count(...) == 0` never evaluates true on an absent series, so
   a detector written that way stays silent forever. Use `absent()` — and then keep the selector wide
   enough that a rename does not read as an outage.
4. **A per-reason allowlist fails silent.** Alerting on the discard reasons you have already seen is
   exactly how the next reason arrives unnoticed. Always carry a catch-all.
