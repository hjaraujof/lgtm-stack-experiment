# Runbook: CollectorExportFailing / CollectorQueueSaturated

**Alerts:**
- `CollectorExportFailing` (critical): `otelcol_exporter_send_failed_{spans,metric_points,log_records}`
  rate > 0 for 5m. The collector cannot deliver to a backend (Tempo, Loki, or Mimir).
- `CollectorQueueSaturated` (warning): export queue >80% full for 10m. The backend is slow or
  unreachable, and drops are imminent.

## What it means
The collector processes telemetry but cannot hand it off downstream. Common causes:

- **Stale connection after a backend recreate.** A `docker compose up -d` recreated Tempo or Mimir,
  the new container got a new IP, and the collector's cached connection still points at the dead old
  one. **Fix: `docker compose restart otel-collector`** so it re-resolves. Restart the collector after
  ANY backend recreate — that is why the deploy procedure does it unconditionally.
- The backend is genuinely down or unhealthy. Check its `/ready`.
- The backend is rejecting with a 4xx — a Mimir ingestion limit, or malformed data.

## First response
1. Which exporter and which signal? Break it down by exporter label:
   `sum by (exporter) (rate(otelcol_exporter_send_failed_spans_total[5m]))`, and the same for
   `_metric_points_total` and `_log_records_total`.
2. Is the target reachable and healthy?
   `curl localhost:3200/ready` (Tempo), `curl localhost:9009/ready` (Mimir),
   `curl localhost:3100/ready` (Loki).
3. Test the network path from inside the collector's network namespace:
   `docker run --rm --network container:otel-collector busybox wget -qO- http://tempo:4318/`
   A 400 or 415 means it is reachable. Connection-refused means stale or down.
4. Reachable, but the collector still fails? That is the stale-connection case. Restart the collector.

## Fix
- Stale connection: `docker compose restart otel-collector`.
- Backend down: recover the backend. The collector's `retry_on_failure` drains the queue afterwards.
- A persistent queue (file_storage extension) preserves in-flight data across a collector restart.
  Without it, whatever sits in the in-memory queue at restart is lost.
