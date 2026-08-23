# Runbook: sustained auth failures (401/403)

**Alert:** `ServiceAuthFailureRateHigh` — more than 10% of inbound requests answered 401 or 403 over
30m, at more than 150 SERVER requests per 30m (warning).

## What it means

The service is authenticating callers and rejecting them. This is **not** an availability breach — the
service is doing its job correctly — so it deliberately does not burn the error budget. See
[service-error-budget.md](service-error-budget.md).

It is still an outage from the caller's side: whatever depends on that auth is down.

**WHY THIS ALERT HAD TO BE ADDED: the failure class is otherwise COMPLETELY INVISIBLE.** Three
independent blind spots line up:

- Under OTel semconv a 4xx does NOT set SERVER span status to Error. So every span-status-based error
  rule reads a 401 storm as perfectly healthy.
- Many web frameworks do not log 4xx responses at all.
- A verifier that returns `null` on a 401, rather than throwing, logs nothing either.

A service can answer the large majority of its credential verifications 401 for days, and the only
way anyone finds out is a manual query prompted by an unrelated alert. That is the shape this rule
converts into a signal.

## First response

1. Which endpoint and which status?
   ```promql
   sum by (span_name, http_response_status_code) (
     rate(traces_span_metrics_calls_total{service_name="<svc>",span_kind="SPAN_KIND_SERVER",http_response_status_code=~"401|403"}[30m])
   )
   ```
2. **401 against 403 is the fork, and it changes who you call.**
   - 401 = the credential was not accepted. Wrong, expired, missing, or revoked.
   - 403 = the credential WAS accepted but lacks the permission. An authorization or tenant-scoping bug.
3. When did it start? Compare the same query with `offset 24h`, and check for a deploy annotation on
   **both** this service and its identity provider near the onset.
4. Is it one caller or all callers? Split by peer in Tempo:
   `{resource.service.name="<svc>" && span.http.response.status_code=401}` and inspect the parent
   service on those traces.

## Common causes

- A credential rotated on ONE side only. The issuer rotated and the verifier still holds the old
  secret, or the reverse.
- Credential records orphaned by a re-mint. Repeated mints for the same (application, environment)
  pair leave prior records stranded, and the caller still presents a stranded one.
- Clock skew invalidating short-lived tokens.
- A tenant or scope change that narrowed what an existing credential may do. That is a 403, not a 401.
- Legitimate: a public endpoint being scanned. Confirm whether the 401s concentrate on one caller or
  user-agent BEFORE you treat this as a break.

## Why the gate is 150 req/30m and not 300

This is the transferable part of the rule, so it is worth understanding rather than copying.

`ServiceLatencySLIBreach` gates at more than 300 requests per 30m because it separates 0.95 from 0.90
— a 5pp band at p about 0.95, where the standard error at n=300 is roughly 1.3pp. A band/SE ratio of
about 3.8.

This alert separates about 0 from 10pp or more, a much WIDER band, so it reaches equivalent confidence
at a much lower n: at n=150 and p=0.10 the standard error is 2.4pp against a 10pp band, a ratio of
about 4.1.

**That difference matters in practice.** A modestly-trafficked auth service can sit near 150 SERVER
requests per 30m, so a copied 300 gate would exclude the exact service this alert exists to catch.

**DERIVE A GATE FROM THE BAND IT MUST RESOLVE, NOT FROM ANOTHER ALERT'S GATE.** And never set one
from a single day's traffic. A service's 30m request count can easily double week
over week, so a gate fitted to one day's reading excludes the service the next.

The 10% threshold is not a placeholder. On a healthy fleet every service reads exactly 0 on this
ratio, so no service's normal operation puts it near the line.

## Escalate if

The rejecting service and the credential issuer are owned by different teams. Both need to be in the
room, because neither side's logs show the failure.
