# Runbook: endpoint failing 100% of requests

**Alert:** `EndpointTotallyFailing` — more than 5 requests in 5m, ZERO successes, sustained 15m
(critical). Live envs only.

## What it means

ONE HTTP handler is failing **every single request**, while the service as a whole may look fine. This
is not a degradation signal. It is a "this endpoint is completely broken" signal.

**Every other error alert in this stack is a service-wide AVERAGE, so all of them are blind to this.**
If a service has one dead endpoint and nine healthy ones, `HighServiceErrorRatio` and the burn-rate
alerts stay quiet, because the healthy nine hold the average under every threshold.

The canonical shape: a deploy ships a task definition missing one required environment variable. Every
call through the endpoint that needs it 500s identically. The load balancer's liveness probe answers
200 throughout, because it is a static liveness check by design. Nothing else in the stack can see it.

## First response

1. Identify the endpoint from `$labels.service_name` and `$labels.span_name`.
2. Confirm and see the history:
   `endpoint:errors:rate5m{service_name="<svc>", span_name="<endpoint>"}` compared with
   `endpoint:requests:rate5m` for the same labels. They should be EQUAL — every request erroring.
3. Get a failing trace. In Explore against Tempo:
   `{resource.service.name="<svc>" && name="<span_name>" && status=error}`, or click a metric exemplar.
   The exception message on the span is usually the whole answer.
4. **CHECK CONFIGURATION BEFORE CODE.** 100% failure from a clean start is far more often a missing
   environment variable than a logic bug: the failure is total and immediate, not load-dependent or
   data-dependent. If the service has a startup preflight, its boot logs name every missing variable
   explicitly. A `/health` that returns 200 tells you nothing here — it is a liveness probe by design.
   A `/health/ready` that reports live dependency state does tell you something.
5. Correlate with a deploy. An annotation at the onset points at the deployed revision, which is where
   a missing variable would have been introduced.

## Common causes

- **A missing or incorrect environment variable in the deployed configuration.** The endpoint's
  dependency cannot be resolved, so every call fails identically.
- A downstream dependency that only this endpoint uses is unreachable. Check the service-graph edge.
- A bad deploy affecting one route. Roll back.
- A route renamed or removed while callers still hit the old path.

## What this alert does NOT cover

**Partial degradation.** An endpoint failing 40% of requests will not fire this. That is DELIBERATE. A
ratio-with-traffic-gate was tried twice at service level and did not survive: the root cause of an
unstable ratio is sample COUNT, not rate, and a per-ENDPOINT denominator is sparser still. See the
sample-count reasoning in [service-latency.md](service-latency.md). A partial per-endpoint signal needs
enough samples to be meaningful, and typically only the highest-traffic services have them.

**Endpoints under about 1 request per minute.** The `>5 requests in 5m` floor suppresses them, so a
broken but rarely-used endpoint will not page here.

## Why this alert is trustworthy where the ratio alerts are not

Unlike every ratio alert in this stack, this one is **immune to a benign-error floor BY
CONSTRUCTION.** A caught-and-handled recurring error is interleaved WITH successful spans, so any
endpoint carrying it has non-error spans and is removed by the `unless` — even at a 90% error rate. A
firing of this alert is never a benign-floor artifact.

## Escalate if

The failing endpoint is on the AUTH path. Every other service's authentication depends on it, so a
total failure there is a fleet-wide outage rather than a single-service one.
