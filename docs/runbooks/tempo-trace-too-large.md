# Runbook: Tempo trace_too_large / untriaged span discards

**Alerts:**
- `TempoTraceTooLarge` (critical) — Tempo discarding spans with `reason="trace_too_large"` or
  `reason="trace_too_large_to_compact"`. A single trace exceeded
  `overrides.defaults.ingestion.max_bytes_per_trace` in `config/tempo-config.yaml`.
- `TempoSpansDiscardedUnknownReason` (warning) — catch-all for any discard reason the rules above do
  not name, so a reason added by a future Tempo release announces itself instead of eating spans in
  silence.

## What it means

`max_bytes_per_trace` is a **per-trace** cap, not a rate or a volume cap. Once a single trace crosses
it, Tempo refuses **every subsequent batch for that trace** while it still accepts other traces. So
the blast radius is not "some spans" — it is **100% of the spans belonging to the offending trace**,
for as long as the producer keeps writing to it.

**THIS IS THE FAILURE MODE SPAN METRICS CANNOT SEE.** The spanmetrics connector runs in the
otel-collector, UPSTREAM of Tempo. It counts spans on the way past, so `traces_span_metrics_*` — and
therefore every RED dashboard, SLO and error-ratio alert in this stack — stays perfectly healthy while
the service is completely invisible in Tempo. Only `tempo_discarded_spans_total` shows it.

Do not conclude "the service is fine" from RED metrics while this alert is firing.

## The diagnostic that identifies the culprit in one step

Tempo logs the offending trace itself. This is faster and more precise than any metric:

```bash
docker logs tempo --since 30m 2>&1 | grep TRACE_TOO_LARGE | tail -5
# level=warn msg=TRACE_TOO_LARGE max=20000000 traceSz=2341 totalSize=36309148 \
#   trace=<TRACE_ID> tenant=single-tenant
```

`totalSize` climbing across successive lines for the **same `trace=`** is the signature of a
never-ending trace, as opposed to one genuinely huge batch. Then name the owner:

```bash
curl -s -H 'Accept: application/json' http://localhost:3200/api/traces/<TRACE_ID> > /tmp/t.json
# resource service.name = the owning service; group span names to find the repeating operation
```

A CAVEAT ON THAT LOOKUP: it can be circular. A trace big enough to be refused may also be too big to
read back. If the API call fails or times out, identify the producer from the COLLECTOR side instead —
the discard log alone does not always carry a service name.

Quantify how blind the service is. If these two are equal, it is losing 100% of its traces:

```promql
rate(tempo_discarded_spans_total{reason="trace_too_large"}[5m])
sum(rate(traces_span_metrics_calls_total{service_name="<svc>"}[5m]))
```

## Common causes

- **A never-closed root span.** By far the most likely. Any long-lived worker whose root span outlives
  its loop pins ONE trace id for the life of the process, so every later span joins it. The classic
  shape is an auto-instrumentation decorator applied to a class whose inherited `run()` method never
  returns: the wrapping span never ends, so it is never exported, and its children appear as ORPHANS
  pointing at a parent absent from the trace while it stays the ambient parent forever.

  **Orphan spans sharing one trace id, with no long-lived span present in the export, is the tell.**

  The fix is a fresh root span per unit of work: start each iteration under `ROOT_CONTEXT` rather than
  inherit the ambient context.

- **A genuinely enormous unit of work.** A batch job fanning tens of thousands of child spans under
  one root. A legitimate shape at the wrong granularity: split it per item or per chunk.

- **Oversized span attributes** inflating a trace with a sane span count. Cross-check for
  `msg="attributes truncated"` in the Tempo log, and keep error payloads under Tempo's
  `max_span_attr_byte`.

- **A second mechanism worth knowing about:** children can attach to a properly ENDED root span many
  hours later. That is not an orphan problem and not a failing retry — it is a context leak that
  survives the root's lifetime. It accumulates with PROCESS UPTIME rather than with traffic, so it
  recurs on a fixed schedule regardless of load, and a fix for the orphan case does not address it.
  If the alert returns after you closed the root-span leak, measure against uptime, not volume.

## Remediation levers, in preference order

1. **Fix the producer.** The correct fix in every runaway-trace case. Bound the trace: one trace per
   tick, request, or batch item.
2. **Raise `max_bytes_per_trace`** only when the trace is legitimately large AND bounded. It does NOT
   help a never-ending trace; it moves the cliff further out and costs more storage and query memory
   before it hits anyway.
3. **Do NOT** silence this by narrowing the alert's `reason` selector. That is the exact defect the
   rule was written to close.

## Note on recovery

The discards stop when the producer stops writing to the oversized trace. For a leaked root span that
means **a restart of the emitting service**, not of Tempo. Restarting Tempo does not help: the trace id
lives in the producer's process. Spans already refused are gone — they are not buffered and not retried.

## Escalate

The fix is almost always source-side. Hand it to the emitting service's owners with the trace id, the
`service.name`, and the repeating span name. That trio is usually enough to locate the offending loop
directly.
