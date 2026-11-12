#!/usr/bin/env python3
"""The two service.name shapes outside the Mimir rules.

Some instrumentation names a service "{env}/{component}" instead of "{tenant}/{env}/{component}".
The Mimir rules have promtool tests for both shapes (tests/mimir-rules/two-segment-service-name.test.yaml).
The collector's keep-lowvolume-envs tail-sampling policy had none, so it is checked here, read out of
the REAL config. It must keep dev and prod traces in both shapes and leave qa and uat to the
probabilistic sampler. The assertions hold whether the processor matches anchored or unanchored, so
they do not depend on which one it does. A negative control proves the old pattern missed a
two-segment dev name, so the check can fail.

Run:  python3 tests/scripts/test-service-name-shapes.py
"""

import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY = "keep-lowvolume-envs"
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


def policy_pattern():
    config = yaml.safe_load((REPO_ROOT / "config/otel-collector-config.yaml").read_text())
    for policy in config["processors"]["tail_sampling"]["policies"]:
        if policy["name"] == POLICY:
            values = policy["string_attribute"]["values"]
            check(len(values) == 1, f"{POLICY} has {len(values)} values, expected 1")
            check(policy["string_attribute"].get("enabled_regex_matching") is True,
                  f"{POLICY} does not set enabled_regex_matching, so its value is a literal string")
            return values[0]
    raise SystemExit(f"{POLICY} policy not found in config/otel-collector-config.yaml")


def kept(pattern, name):
    """True only when both anchored and unanchored matching keep the name, so the result holds either way."""
    return bool(re.fullmatch(pattern, name)) and bool(re.search(pattern, name))


def dropped(pattern, name):
    return not re.fullmatch(pattern, name) and not re.search(pattern, name)


pattern = policy_pattern()
for name in ("dev/orders-api", "prod/orders-api", "tenant-a/dev/auth-api", "tenant-b/prod/web-portal"):
    check(kept(pattern, name), f"{POLICY} {pattern!r} does not keep {name}")
for name in ("qa/orders-api", "tenant-a/qa/auth-api", "uat/orders-api", "tenant-b/uat/tasks-api"):
    check(dropped(pattern, name), f"{POLICY} {pattern!r} keeps {name}, which belongs to the sampler")
# Negative control: the old pattern needed a slash before the env, so it missed a two-segment name.
# If this ever passes, the check above could not tell the old pattern from the new one.
check(not re.search(r".*/(dev|prod)/.*", "dev/orders-api"),
      "negative control: the old pattern matched dev/orders-api, so this test cannot detect a regression")

if failures:
    print("FAILED:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"OK: {POLICY} {pattern!r} keeps dev and prod in both name shapes and leaves qa and uat to the sampler")
