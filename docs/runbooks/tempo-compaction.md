# Runbook: Tempo compaction stalled

**Alert:** `TempoCompactionStalled` — `tempodb_compaction_outstanding_blocks > 50` for 15m (warning).

A silent-failure mode: blocks are not compacting into object storage.

## What it means
Tempo's compactor is falling behind. Outstanding blocks accumulate on local disk, which is the
disk-full risk, and query performance degrades.

## First response
1. `curl -s localhost:3200/metrics | grep -E 'compaction_outstanding|compaction_errors'`
   The Tempo image is distroless, so `docker exec` gives you no shell. Read the endpoint from the host.
2. Object-store reachability. Compaction WRITES to object storage, so a storage access failure stalls
   it. Cross-check `MimirBlockUploadOrCompactionFailing` — it has the same dependency, and if both
   fire together the storage path is the single cause.
3. Disk headroom: `df -h /`.
4. Compactor logs: `docker compose logs --tail 100 tempo | grep -i compact`.

## Common causes
- Object-store write failures (IAM, endpoint, or permissions).
- The compactor is under-resourced during a traffic spike. This stack is CPU-bound.
- A backlog from a prior outage that is draining slowly. This one may self-resolve — watch the
  direction of travel before you act.

## Escalate
If outstanding blocks keep climbing, or disk approaches full, treat it as the disk-full track. Do not
wait for a self-resolve you have not seen evidence of.
