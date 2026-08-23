#!/usr/bin/env python3
"""Integration test for scripts/init-mimir-alertmanager.sh against a fake Mimir config API.

WHY THIS IS AN INTEGRATION TEST AND NOT A UNIT TEST
---------------------------------------------------
The behaviour under test is "does an out-of-band write to the tenant config get reverted", and the
thing that makes that work is the HTTP round-trip: Mimir returns the config wrapped in a YAML
document with the body as a four-space-indented block scalar, so a naive comparison of the response
against the git file ALWAYS reports a mismatch. Mocking the round-trip would mock away the exact step
that has to be right. So this stands up a real socket and speaks the real wire format.

It also runs a NEGATIVE CONTROL (test_control_oneshot_does_not_repair): the same out-of-band write
against one-shot behaviour, asserting the config is NOT repaired. Without that control, a test suite
that never exercises the loop passes just as happily with the loop deleted.

Run:  python3 tests/scripts/test-am-reconcile.py
"""

import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "init-mimir-alertmanager.sh"

# Must contain every marker the script's verify step asserts on, or the initial load fails.
SAMPLE_CONFIG = """route:
  receiver: sns-warning
  group_by: [alertname, service_name]
  routes:
    - matchers: [alertname="Watchdog"]
      receiver: sns-watchdog

receivers:
  - name: sns-critical
  - name: sns-warning
  - name: sns-watchdog
"""

DRIFTED_CONFIG = """route:
  receiver: sns-warning

receivers:
  - name: sns-critical
  - name: sns-warning
  - name: sns-watchdog
"""


class FakeMimir(http.server.BaseHTTPRequestHandler):
    """In-memory stand-in for Mimir's /ready and /api/v1/alerts tenant config API."""

    stored = ""          # the tenant's alertmanager_config, as Mimir would hold it
    post_count = 0

    def log_message(self, format, *args):  # noqa: A002 - signature fixed by BaseHTTPRequestHandler
        del format, args  # keep test output readable

    def _send(self, code, body=b"", ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/ready":
            return self._send(200, b"ready")
        if self.path == "/api/v1/alerts":
            # Reproduce Mimir's exact serialisation: an empty config comes back as the quoted empty
            # string -- this is the literal response a wiped tenant serves -- and anything else comes
            # back as a block scalar.
            if FakeMimir.stored == "":
                body = 'template_files: {}\nalertmanager_config: ""\n'
            else:
                indented = "".join(
                    ("    " + line if line else "") + "\n"
                    for line in FakeMimir.stored.split("\n")[:-1]
                )
                body = "template_files: {}\nalertmanager_config: |\n" + indented
            return self._send(200, body.encode(), "application/yaml")
        return self._send(404)

    def do_POST(self):
        if self.path != "/api/v1/alerts":
            return self._send(404)
        length = int(self.headers.get("Content-Length", 0))
        payload = json.loads(self.rfile.read(length).decode())
        FakeMimir.stored = payload["alertmanager_config"]
        FakeMimir.post_count += 1
        return self._send(201, b"created")


def start_server():
    srv = http.server.HTTPServer(("127.0.0.1", 0), FakeMimir)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def run_script(url, config_path, interval, wait):
    """Launch the script in its own process group so the loop can be torn down reliably."""
    env = {
        **os.environ,
        "MIMIR_URL": url,
        "TENANT": "demo",
        "AM_CONFIG_FILE": str(config_path),
        "RECONCILE_INTERVAL_SECS": str(interval),
        "READY_TIMEOUT_SECS": "10",
    }
    proc = subprocess.Popen(
        ["bash", str(SCRIPT)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )
    time.sleep(wait)
    return proc


def stop(proc):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        return proc.communicate(timeout=5)[0]
    except subprocess.TimeoutExpired:
        return ""


def reset(tmpdir, contents=SAMPLE_CONFIG):
    FakeMimir.stored = ""
    FakeMimir.post_count = 0
    path = Path(tmpdir) / "demo-am.yaml"
    path.write_text(contents)
    return path


FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def test_initial_load(url, tmpdir):
    print("test_initial_load: a cold start loads git's config")
    path = reset(tmpdir)
    proc = run_script(url, path, interval=1, wait=3)
    out = stop(proc)
    check("config stored matches git", FakeMimir.stored == SAMPLE_CONFIG,
          f"stored={FakeMimir.stored!r}")
    check("verify step ran", "verified:" in out, out[-300:])


def test_no_pointless_repost(url, tmpdir):
    print("test_no_pointless_repost: a steady state must not re-POST (it would move the config hash)")
    path = reset(tmpdir)
    proc = run_script(url, path, interval=1, wait=5)
    stop(proc)
    check("exactly one POST across ~4 reconcile ticks", FakeMimir.post_count == 1,
          f"post_count={FakeMimir.post_count}")


def test_reverts_out_of_band_write(url, tmpdir):
    print("test_reverts_out_of_band_write: an empty-config write self-heals")
    path = reset(tmpdir)
    proc = run_script(url, path, interval=1, wait=3)
    check("loaded before tampering", FakeMimir.stored == SAMPLE_CONFIG)

    FakeMimir.stored = ""          # the out-of-band write, byte for byte
    posts_before = FakeMimir.post_count
    time.sleep(4)
    out = stop(proc)

    check("empty config was reverted to git", FakeMimir.stored == SAMPLE_CONFIG,
          f"stored={FakeMimir.stored!r}")
    check("a reconcile POST was issued", FakeMimir.post_count > posts_before)
    check("drift was logged", "DRIFT:" in out, out[-300:])


def test_reverts_partial_overwrite(url, tmpdir):
    print("test_reverts_partial_overwrite: a plausible-looking wrong config is also reverted")
    path = reset(tmpdir)
    proc = run_script(url, path, interval=1, wait=3)

    FakeMimir.stored = DRIFTED_CONFIG   # valid, passes every marker check, still not git
    time.sleep(4)
    stop(proc)

    check("drifted config reverted to git", FakeMimir.stored == SAMPLE_CONFIG,
          f"stored={FakeMimir.stored!r}")


def test_picks_up_git_change(url, tmpdir):
    print("test_picks_up_git_change: editing the file (i.e. `git pull`) deploys without a restart")
    path = reset(tmpdir)
    proc = run_script(url, path, interval=1, wait=3)

    updated = SAMPLE_CONFIG.replace("group_by: [alertname, service_name]", "group_by: [alertname]")
    path.write_text(updated)
    time.sleep(4)
    stop(proc)

    check("new file content deployed", FakeMimir.stored == updated,
          f"stored={FakeMimir.stored!r}")


def test_control_oneshot_does_not_repair(url, tmpdir):
    """NEGATIVE CONTROL - one-shot behaviour, asserting the tests above are not vacuous."""
    print("test_control_oneshot_does_not_repair: with the loop OFF, drift must persist")
    path = reset(tmpdir)
    proc = run_script(url, path, interval=0, wait=3)
    proc.wait(timeout=10)
    check("one-shot mode exits 0", proc.returncode == 0, f"rc={proc.returncode}")
    check("loaded before tampering", FakeMimir.stored == SAMPLE_CONFIG)

    FakeMimir.stored = ""
    time.sleep(4)
    check("drift is NOT repaired without the loop", FakeMimir.stored == "",
          "the loop-based tests above would pass even with the loop removed")


def main():
    if not SCRIPT.exists():
        sys.exit(f"script not found: {SCRIPT}")
    srv, url = start_server()
    try:
        with tempfile.TemporaryDirectory() as tmpdir:
            for t in (
                test_initial_load,
                test_no_pointless_repost,
                test_reverts_out_of_band_write,
                test_reverts_partial_overwrite,
                test_picks_up_git_change,
                test_control_oneshot_does_not_repair,
            ):
                t(url, tmpdir)
    finally:
        srv.shutdown()

    print()
    if FAILURES:
        print(f"FAILED ({len(FAILURES)}): {', '.join(FAILURES)}")
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
