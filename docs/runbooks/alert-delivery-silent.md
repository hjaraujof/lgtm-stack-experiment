# Runbook: the alert path itself is broken

**Alarms and alerts:** the CloudWatch watchdog alarm (the one that will actually reach you),
`AlertDeliverySilent`, `AlertmanagerConfigChanged`.

## Read this first

If you are reading this because of the **CloudWatch** alarm, assume **every other LGTM alert is
currently going nowhere**. Do not read a quiet notification channel as a quiet stack. Check the firing
list directly in Grafana (Alerting, Mimir-Alertmanager) or on the box before you conclude that anything
is healthy.

`AlertDeliverySilent` and `AlertmanagerConfigChanged` are evaluated by the ruler and delivered by the
Alertmanager, so **in the exact failure they describe they cannot be delivered.** They exist for
dashboard visibility and for PARTIAL failures, where some integrations are dead and others alive. The
out-of-band CloudWatch alarm on the watchdog topic is the real detector.

## The failure mode this exists for

The Mimir Alertmanager tenant config is replaced with an **empty** one through the config API. A config
with no `route` and no `receivers` is VALID, and it dispatches nothing.

Every component stays "healthy" and every metric looks fine:

| Signal | Value during the outage | What it looks like |
|---|---|---|
| `cortex_prometheus_notifications_sent_total` | climbing, **0 errors, 0 dropped** | ruler perfectly healthy |
| `cortex_alertmanager_alerts_received_total` | climbing | Alertmanager receiving fine |
| `cortex_alertmanager_notifications_total` | **the series does not exist** | nothing dispatched, ever |
| Downstream publishes | **0/day** | silence reads as "nothing wrong" |

**THE TRANSFERABLE LESSON: never read alert silence as health.** The only thing that watched the alert
path was the alert path, so this class of outage runs for days and is found by manually diffing the
deployed box against git. That is why this stack has a permanently-firing `Watchdog` rule routed to a
dedicated, unsubscribed topic, with a CloudWatch alarm on that topic's publish count.

## Triage

1. **Is the config still there?**
   ```bash
   curl -s -H 'X-Scope-OrgID: demo' http://localhost:9009/api/v1/alerts | head -5
   ```
   `alertmanager_config: ""`, or a response of only a few hundred characters of `global:` defaults,
   means the config has been wiped.

2. **Is it dispatching?**
   ```bash
   curl -s http://localhost:9009/metrics | grep cortex_alertmanager_notification
   ```
   **AN ABSENT METRIC IS THE FAILURE**, not a missing tool. The Alertmanager only registers
   `cortex_alertmanager_notifications_total` per integration once it has dispatched at least once.
   Never write a detector for this as a bare `== 0` — it silently matches nothing. Use `absent()`.

3. **Is it the ruler or the Alertmanager?** `cortex_prometheus_notifications_sent_total` climbing while
   `cortex_alertmanager_notifications_total` is absent or flat isolates the fault to the Alertmanager.

4. **Is it the publish path rather than the config?**
   `cortex_alertmanager_notification_errors_total{integration="sns"}` climbing means the Alertmanager
   IS trying and failing — usually the instance role missing `sns:Publish` on a topic. The receiver
   list in `demo-am.yaml` and the IAM policy in `alerting.tf` must stay in step. If you add a receiver
   and forget the policy, this is the symptom.

## Fix

**This should already have fixed itself.** `mimir-am-init` is a long-running RECONCILER, not a one-shot
loader: it compares the live tenant config with `config/mimir/alertmanager/demo-am.yaml` every
`RECONCILE_INTERVAL_SECS` and re-POSTs git's copy whenever they differ. An out-of-band write survives
at most one interval.

So check the reconciler FIRST. If the config is still wrong, the reconciler is what is broken:

```bash
docker ps --filter name=mimir-am-init            # must be Up, not Exited
docker logs mimir-am-init --tail 50 | grep -E 'DRIFT|WARNING|ERROR'
```

`DRIFT:` lines name the time and both byte counts. A container in `Exited` state is the real fault.
Restart it and the config follows within one interval:

```bash
docker compose up -d mimir-am-init
```

Manually, if the loader itself is broken:

```bash
jq -Rs '{template_files: {}, alertmanager_config: .}' \
  config/mimir/alertmanager/demo-am.yaml > /tmp/am.json
curl -sS -w 'HTTP:%{http_code}\n' -X POST -H 'X-Scope-OrgID: demo' \
  --data-binary @/tmp/am.json http://localhost:9009/api/v1/alerts
```

Expect `HTTP:201`. **Do NOT POST the raw `demo-am.yaml`.** The endpoint wants the wrapper document
with the config as a STRING under `alertmanager_config`, and posting the raw file is a no-op shaped
like a success.

Verify within one interval: `cortex_alertmanager_notifications_total` appears, and a heartbeat publish
shows on the watchdog topic in CloudWatch.

## How to reason about who could have written it

**"Nobody could have done this" is not an argument. Enumerate the paths and MEASURE them.** Two lessons
from doing exactly that:

- **Do not assume a port is open because it feels like it should be.** Read the security group's
  ingress rules and list them. Mimir's `:9009` may well not be among them, in which case its config
  API is reachable only from the box itself.
- **The reachable path is often the one that bypasses your reverse proxy.** If Grafana's port is open
  to the VPC as a "direct access fallback", a VPC client can drive the Mimir config API through
  Grafana's datasource proxy — and that route does NOT traverse nginx, so any `limit_except` guard on
  the 443 vhost does not cover it. Closing the browser-facing route over 443 does not close it.
- **A datasource that looks configured may never have worked.** A Mimir Alertmanager datasource whose
  URL already ends in `/alertmanager` double-prefixes, because Grafana appends that path itself for
  `implementation: mimir`. Every request then resolves to a removed v1 API endpoint and answers
  `410 Gone`. Verify a path works before you name it as a suspect — and before you rule it out.

If object-store data events are not enabled on the bucket, an actor may be genuinely
unidentifiable after the fact. `AlertmanagerConfigChanged` is what covers the remainder: it turns the
next write into a signal even when it cannot name the writer.
