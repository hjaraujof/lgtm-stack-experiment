# Runbook: Loki discarding log entries

**Alerts:**
- `LokiSamplesDiscarded` (warning): `rate(loki_discarded_samples_total) > 0` by tenant and reason,
  for 15m. These entries are permanently lost.
- `LokiTenantFakeIngest` (warning): active streams exist on the `fake` tenant, for 5m.

## Why this class goes unnoticed
**Loki validates PER ENTRY.** An oversized entry is discarded and counted, the rest of the push is
still ingested, and the whole request answers 400. That partial-success shape means the service keeps
logging normally, its own logs look fine, and a large fraction of its entries are silently destroyed.
A service can lose gigabytes over weeks this way while every dashboard reads healthy.

The alert is deliberately UNSCOPED by reason. To scope a discard alert to the one reason you have seen
so far is exactly how the next reason arrives in silence.

## First response for LokiSamplesDiscarded
1. Read the reason and tenant off the alert, then confirm the rate:
   `sum by (tenant, reason) (rate(loki_discarded_samples_total[15m]))`
2. **`structured_metadata_too_large`** — a producer is attaching more structured metadata per entry
   than `max_structured_metadata_size` allows. Raise that limit in `config/loki-config.yaml`, or
   reduce what the producer attaches. Check `max_structured_metadata_entries_count` too.
3. **`line_too_long`** — raise `max_line_size`, or fix the producer.
4. **`rate_limited`** — the tenant is over `ingestion_rate_mb` or `ingestion_burst_size_mb`.
5. **`out_of_order`** — a producer is sending entries with going-backwards timestamps.
6. Any reason not listed here: add it to this runbook once you have diagnosed it. A runbook that only
   documents the reasons already hit has the same weakness as an alert scoped to them.

## First response for LokiTenantFakeIngest
`fake` is the tenant Loki uses when a push carries no `X-Scope-OrgID` header. Those entries route to
whatever the OLDEST schema period defines, which is rarely what you want and may not flush at all on
a current Loki release.

1. Confirm: `sum(loki_ingester_memory_streams{tenant="fake"})`. This is a GAUGE, so no `rate()` and no
   `_total` suffix. Recent Loki releases removed the per-tenant received-lines counter, so the
   memory-streams gauge is the per-tenant signal that remains.
2. Find the headerless producer. The collector's `otlphttp/loki` exporter sets the tenant header, so
   the usual cause is a NEW producer or exporter that writes to Loki directly and skips it.
3. Fix at the source: set `X-Scope-OrgID` on the push. Expected steady state on this stack is ZERO
   fake streams.
