# Runbook: Mimir block upload / compaction failing

**Alert:** `MimirBlockUploadOrCompactionFailing` — `cortex_ingester_shipper_upload_failures_total` or
`cortex_compactor_runs_failed_total` rising for 15m (critical).

Silent data-loss risk: the TSDB head grows without bound, the ingester OOMs, and in-memory data is
gone.

## What it means
Mimir cannot ship TSDB blocks to object storage, or cannot compact them. The local TSDB head keeps
growing on the instance disk, which is also the disk-full track.

## First response
1. Read the two counters directly:
   `curl -s localhost:9009/metrics | grep -E 'shipper_upload_failures|compactor_runs_failed'`
2. **Object-store access is the usual culprit**, and it is the SAME dependency as
   `TempoCompactionStalled`. If both alerts fire together, suspect the storage path first, not two
   independent bugs.
   - Is the instance IAM role still valid? Is the S3 gateway endpoint up? Is the metrics bucket
     reachable and writable?
   - `docker compose logs --tail 100 mimir | grep -iE 's3|upload|compact|error'`
3. Check disk and memory headroom: `df -h /` and the ingester's RSS. An unbounded head is the danger.

## Common causes
- Object-store permission or endpoint failure, so blocks cannot upload.
- The compactor crashing on a corrupt block.
- Disk full, which prevents local block writes.

## Escalate
Critical. An unbounded head plus a potential ingester OOM equals data loss. Restore the object-store
write path first; everything else is secondary.
