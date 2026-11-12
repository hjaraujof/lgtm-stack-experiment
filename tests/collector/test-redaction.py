#!/usr/bin/env python3
"""Regression test for the secret redaction in config/otel-collector-config.yaml.

WHAT IT PROVES
--------------
The collector job's `validate` proves that the OTTL statements PARSE. It cannot prove what they
match: a pattern that matches nothing, or one that eats the rest of the query string, validates
cleanly. So this runs the statements in the pinned collector image and asserts on the output:
  - the value of every secret parameter (code, state, token, continue, access_token, id_token,
    refresh_token) becomes REDACTED, on every span attribute that carries a URL, on the log
    `context` attribute and on the log body;
  - everything else survives byte for byte: clientId, returnUrl, code_challenge, xtoken, the other
    parameters, the #fragment, and the JSON around a URL inside the `context` attribute.
It also checks the WIRING, because a processor that is defined but absent from its pipeline
validates cleanly too.

NO FIXTURE COPY OF THE STATEMENTS
---------------------------------
Both processors are loaded out of the real config file and run verbatim. A copied fixture keeps
passing after the real statements change, which is the failure this test exists to catch.

NEGATIVE CONTROL
----------------
The run is repeated with `token` removed from every statement, and the test FAILS unless the
assertions then report the raw token. Without that, assertions that could not see a raw value
would pass just as well with the redaction deleted.

Needs docker and PyYAML (both on ubuntu-latest). Run from anywhere:
    python3 tests/collector/test-redaction.py
The image is $COLLECTOR_IMAGE when set (config-check.yml sets it), else the otel-collector image in
docker-compose.yml, so the test runs the version that production runs.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG = REPO_ROOT / "config" / "otel-collector-config.yaml"
COMPOSE = REPO_ROOT / "docker-compose.yml"

TRACE_PROCESSOR = "transform/normalize"
LOG_PROCESSOR = "transform/redact_logs"

SECRETS = ["code", "state", "token", "continue", "access_token", "id_token", "refresh_token"]

# One distinct raw value per parameter, so a leak names the parameter that leaked.
RAW = {name: f"SECRET-{name}-v4lue" for name in SECRETS}
REDACTED = {name: "REDACTED" for name in SECRETS}

# code opens the query, so url.query (which has no leading `?`) exercises the `^` anchor.
# code_challenge and xtoken contain a secret name, so a pattern that loses its `=` or its `[?&]`
# anchor redacts them. refresh_token is last, directly before the #fragment in the URL forms, so a
# match that runs past `#` eats the fragment.
QUERY = (
    "code={code}&clientId=client-abc&state={state}"
    "&returnUrl=https%3A%2F%2Fportal.example.com%2Fdashboard&token={token}"
    "&code_challenge=keep-challenge&continue={continue}&xtoken=keep-xtoken"
    "&access_token={access_token}&other=keep-other&id_token={id_token}"
    "&refresh_token={refresh_token}"
)
ACCESS = "https://access.example.com/api/auth/client-logout"


def span_attributes(values):
    query = QUERY.format(**values)
    return {
        "http.target": f"/api/auth/client-logout?{query}#keep-fragment",
        "http.url": f"{ACCESS}?{query}#keep-fragment",
        "url.full": f"{ACCESS}?{query}#keep-fragment",
        "url.query": query,
        "next.span_name": f"fetch GET {ACCESS}?{query}",
    }


def log_records(values):
    """(body, context) pairs, shaped like a transport that serialises extra fields into one `context` string."""
    return [
        # A logout line: the URL is a JSON string value, followed by more JSON.
        (
            "Will redirect to logout URL",
            json.dumps({"logoutRedirectUrl": f"{ACCESS}?{QUERY.format(**values)}",
                        "module": "auth:logout"}, separators=(",", ":")),
        ),
        # A URL inside a quoted string inside a JSON string: the value ends at `\"`, not `"`.
        (
            "Redirecting to https://portal.example.com/api/auth/callback"
            f"?code={values['code']}&state={values['state']}",
            json.dumps({"error": f'fetch failed for "{ACCESS}?token={values["token"]}" after 3 tries'},
                       separators=(",", ":")),
        ),
    ]


def otlp_value(value):
    return {"stringValue": value}


def otlp_attributes(mapping):
    return [{"key": k, "value": otlp_value(v)} for k, v in mapping.items()]


RESOURCE = {"attributes": otlp_attributes({"service.name": "tenant-a/dev/redaction-test"})}


def traces_payload():
    now = time.time_ns()
    return {"resourceSpans": [{"resource": RESOURCE, "scopeSpans": [{
        "scope": {"name": "test-redaction"},
        "spans": [{
            "traceId": "5b8efff798038103d269b633813fc60c",
            "spanId": "eee19b7ec3c1b174",
            "name": "GET /api/auth/client-logout",
            "kind": 2,
            "startTimeUnixNano": str(now - 1_000_000),
            "endTimeUnixNano": str(now),
            "attributes": otlp_attributes(span_attributes(RAW)),
        }],
    }]}]}


def logs_payload():
    now = str(time.time_ns())
    records = [{
        "timeUnixNano": now,
        "observedTimeUnixNano": now,
        "severityNumber": 9,
        "severityText": "INFO",
        "body": otlp_value(body),
        "attributes": otlp_attributes({"context": context}),
    } for body, context in log_records(RAW)]
    return {"resourceLogs": [{"resource": RESOURCE, "scopeLogs": [{
        "scope": {"name": "test-redaction"}, "logRecords": records}]}]}


def collector_image():
    image = os.environ.get("COLLECTOR_IMAGE")
    if image:
        return image
    return yaml.safe_load(COMPOSE.read_text())["services"]["otel-collector"]["image"]


def minimal_config(processors):
    return {
        "extensions": {"health_check": {"endpoint": "0.0.0.0:13133"}},
        "receivers": {"otlp": {"protocols": {"http": {"endpoint": "0.0.0.0:4318"}}}},
        "processors": processors,
        # sampling_initial above the record count: the debug logger otherwise drops repeats.
        "exporters": {"debug": {"verbosity": "detailed", "sampling_initial": 100}},
        "service": {
            "extensions": ["health_check"],
            "pipelines": {
                "traces": {"receivers": ["otlp"], "processors": [TRACE_PROCESSOR], "exporters": ["debug"]},
                "logs": {"receivers": ["otlp"], "processors": [LOG_PROCESSOR], "exporters": ["debug"]},
            },
        },
    }


def docker(*args, check=True):
    return subprocess.run(["docker", *args], check=check, capture_output=True, text=True)


def host_port(cid, port):
    # `docker port` prints one line per address family; the -p flags bind 127.0.0.1 only.
    return docker("port", cid, f"{port}/tcp").stdout.split()[0]


def post(url, payload):
    request = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError(f"POST {url} answered {response.status}")


def run_collector(image, processors):
    """Start the collector with only the given processors, send the fixtures, return its output."""
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "c.yaml"
        # YAML is a superset of JSON, and the collector expands $${...} in either form.
        path.write_text(json.dumps(minimal_config(processors), indent=2))
        path.chmod(0o644)  # the image runs as UID 10001; mkstemp-style 0600 is unreadable to it
        cid = docker("run", "-d", "-p", "127.0.0.1::4318", "-p", "127.0.0.1::13133",
                     "-v", f"{path}:/c.yaml:ro", image, "--config=/c.yaml").stdout.strip()
        try:
            health = f"http://{host_port(cid, 13133)}/"
            deadline = time.monotonic() + 60
            while True:
                try:
                    with urllib.request.urlopen(health, timeout=2) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, ConnectionError):
                    pass
                if time.monotonic() > deadline:
                    raise RuntimeError("collector never became healthy:\n" + logs_of(cid))
                time.sleep(0.5)

            otlp = f"http://{host_port(cid, 4318)}"
            post(f"{otlp}/v1/traces", traces_payload())
            post(f"{otlp}/v1/logs", logs_payload())

            deadline = time.monotonic() + 30
            while True:
                output = logs_of(cid)
                if output.count("Span #") >= 1 and output.count("LogRecord #") >= len(log_records(RAW)):
                    return output
                if time.monotonic() > deadline:
                    raise RuntimeError("the debug exporter never printed the fixtures:\n" + output)
                time.sleep(0.5)
        finally:
            docker("rm", "-f", cid, check=False)


def logs_of(cid):
    result = subprocess.run(["docker", "logs", cid], capture_output=True, text=True)
    return result.stdout + result.stderr


ATTRIBUTE_LINE = re.compile(r"^\s*-> (?P<key>[\w.]+): Str\((?P<value>.*)\)$")
BODY_LINE = re.compile(r"^Body: Str\((?P<value>.*)\)$")


def parse(output):
    attributes, bodies = {}, []
    for line in output.splitlines():
        if match := ATTRIBUTE_LINE.match(line):
            attributes.setdefault(match["key"], []).append(match["value"])
        elif match := BODY_LINE.match(line):
            bodies.append(match["value"])
    return attributes, bodies


def check(output):
    """Every mismatch between the exporter output and the fully redacted fixtures."""
    failures = []
    attributes, bodies = parse(output)

    for key, want in span_attributes(REDACTED).items():
        got = attributes.get(key, [])
        if got != [want]:
            failures.append(f"span {key}:\n    got  {got!r}\n    want {[want]!r}")

    want_records = log_records(REDACTED)
    for label, got, want in (("log context", attributes.get("context", []), [c for _, c in want_records]),
                             ("log body", bodies, [b for b, _ in want_records])):
        if sorted(got) != sorted(want):
            failures.append(f"{label}:\n    got  {sorted(got)!r}\n    want {sorted(want)!r}")

    if leaked := leaked_secrets(output):
        failures.append(f"raw value reached the exporter for: {', '.join(sorted(leaked))}")
    return failures


def leaked_secrets(output):
    return {name for name, raw in RAW.items() if raw in output}


def check_wiring(config):
    """The processors must sit in every pipeline that takes OTLP traces or logs."""
    failures, checked = [], set()
    for name, pipeline in config["service"]["pipelines"].items():
        signal = name.split("/")[0]
        if "otlp" not in pipeline.get("receivers", []) or signal not in ("traces", "logs"):
            continue
        checked.add(signal)
        wanted = TRACE_PROCESSOR if signal == "traces" else LOG_PROCESSOR
        if wanted not in pipeline.get("processors", []):
            failures.append(f"pipeline {name} receives OTLP {signal} without {wanted}")
    for signal in ("traces", "logs"):
        if signal not in checked:
            failures.append(f"no pipeline receives OTLP {signal} - the wiring check is vacuous")
    return failures


def without_token(processors):
    """The negative control: drop `token` from every statement's alternation."""
    mutated = json.loads(json.dumps(processors))
    changed = 0
    for processor in mutated.values():
        for group in processor.get("trace_statements", []) + processor.get("log_statements", []):
            statements = group["statements"]
            for i, statement in enumerate(statements):
                if "|token|" in statement:
                    statements[i] = statement.replace("|token|", "|")
                    changed += 1
    return mutated, changed


def main():
    config = yaml.safe_load(CONFIG.read_text())
    processors = {name: config["processors"][name] for name in (TRACE_PROCESSOR, LOG_PROCESSOR)}
    image = collector_image()
    print(f"image: {image}")

    failures = check_wiring(config)
    if failures:
        print("FAIL: wiring\n  " + "\n  ".join(failures))
        return 1
    print("OK: both redaction processors are in every pipeline that receives OTLP traces or logs")

    failures = check(run_collector(image, processors))
    if failures:
        print("FAIL: redaction\n  " + "\n  ".join(failures))
        return 1
    print(f"OK: {len(SECRETS)} secret parameters redacted on {len(span_attributes(RAW))} span "
          f"attributes and on log context + body; every other parameter, the fragment and the "
          f"surrounding JSON survived")

    mutated, changed = without_token(processors)
    if changed == 0:
        print("FAIL: control could not find `|token|` in any statement - update without_token(), "
              "or the control proves nothing")
        return 1
    # Exactly `token` must leak: none proves the assertions blind, any other proves the control
    # changed more than the one alternative it claims to.
    output = run_collector(image, mutated)
    control, leaked = check(output), leaked_secrets(output)
    if not control or leaked != {"token"}:
        print(f"FAIL: control - with `token` removed from {changed} statement(s), the leaked set was "
              f"{sorted(leaked)!r}, expected ['token']. The assertions cannot be trusted:\n  "
              + "\n  ".join(control))
        return 1
    print(f"OK: control - removing `token` from {changed} statement(s) leaks exactly the raw token, "
          f"and the assertions report it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
