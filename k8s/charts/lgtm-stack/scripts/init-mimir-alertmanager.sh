#!/usr/bin/env bash
#
# Reconcile the git-tracked Mimir Alertmanager tenant config into Mimir, continuously.
#
# WHY THIS EXISTS
# ---------------
# config/mimir/rules/ is bind-mounted read-only and IS the ruler's rule source, so `git pull`
# deploys rules (see the ruler_storage note in config/mimir-config.yaml). The Alertmanager config has
# no such path: alertmanager_storage is object storage, the git file is mounted nowhere, and the only
# way it reaches Mimir is somebody remembering to run `mimirtool alertmanager load` by hand.
#
# THE FAILURE THAT ASYMMETRY PRODUCES: an empty config is written to that object out of band. The
# ruler keeps sending with zero errors and the Alertmanager keeps accepting, and it dispatches
# NOTHING, because a config with no route and no receivers has nowhere to send. Nobody notices,
# because the only thing watching the alert path is the alert path.
#
# WHY IT LOOPS RATHER THAN LOADING ONCE
# -------------------------------------
# One-shot loading leaves the two config planes asymmetric. The box runs `git pull`, the ruler picks
# the new RULES up off its read-only bind mount within a poll interval, and the Alertmanager config
# does not move at all, because nothing re-runs this script. `git pull` deploys half the commit,
# silently.
#
# Polling here mirrors ruler.poll_interval in config/mimir-config.yaml, and gives two properties that
# one-shot loading cannot:
#   - `git pull` alone deploys the Alertmanager config, exactly as it already deploys rules.
#   - An out-of-band write is REVERTED within one interval, instead of surviving indefinitely.
#
# IDEMPOTENCE: a POST only happens when the live config differs from the file. Mimir derives the
# tenant config hash from the content, so an unchanged config is never re-posted and
# cortex_alertmanager_config_hash stays put. An ordinary redeploy therefore does not trip the
# AlertmanagerConfigChanged alert.
set -euo pipefail

MIMIR_URL="${MIMIR_URL:-http://mimir:9009}"
TENANT="${TENANT:-demo}"
AM_CONFIG_FILE="${AM_CONFIG_FILE:-/config/demo-am.yaml}"
READY_TIMEOUT_SECS="${READY_TIMEOUT_SECS:-300}"
# 0 disables the loop and restores strict one-shot behaviour (used by CI and one-off manual loads).
RECONCILE_INTERVAL_SECS="${RECONCILE_INTERVAL_SECS:-60}"

log() { echo "[mimir-am-init] $*"; }
fail() { echo "[mimir-am-init] ERROR: $*" >&2; exit 1; }
warn() { echo "[mimir-am-init] WARNING: $*" >&2; }

[ -s "$AM_CONFIG_FILE" ] || fail "config file $AM_CONFIG_FILE is missing or empty - refusing to post an empty Alertmanager config, which is the exact failure this script exists to prevent"

# --- Wait for Mimir ------------------------------------------------------------------------
# Mimir is monolithic here (-target=all,alertmanager) so /ready covers the Alertmanager too.
log "waiting up to ${READY_TIMEOUT_SECS}s for Mimir at ${MIMIR_URL}"
deadline=$(( $(date +%s) + READY_TIMEOUT_SECS ))
until curl -sf -o /dev/null "${MIMIR_URL}/ready"; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "Mimir did not become ready within ${READY_TIMEOUT_SECS}s"
    sleep 5
done
log "Mimir is ready"

payload=$(mktemp)
live_raw=$(mktemp)
live_body=$(mktemp)
# Snapshots taken at our own last successful POST: what we sent, and what came back. Together they
# tell "someone overwrote the config" apart from "our round-trip is lossy", which need opposite
# responses. Both are needed - see the non-convergence guard in reconcile().
posted_body=$(mktemp)
posted_source=$(mktemp)
trap 'rm -f "$payload" "$live_raw" "$live_body" "$posted_body" "$posted_source"' EXIT

# Mimir answers the config API with a WRAPPER document, not the raw file: the body is a literal block
# scalar indented four spaces under `alertmanager_config:`. Comparing the response against the file
# directly always reports a mismatch, so the body must be unwrapped before any diff means anything.
#
# An empty config serialises as `alertmanager_config: ""`, which matches no block and unwraps to
# nothing - so it correctly reads as "differs from git" and triggers a reconcile. The empty-config
# outage therefore self-heals.
unwrap_body() {
    awk '
        /^alertmanager_config: \|/ { inbody = 1; next }
        inbody {
            if ($0 == "") { print ""; next }
            if (substr($0, 1, 4) == "    ") { print substr($0, 5); next }
            exit
        }
    '
}

# A 2xx means Mimir stored SOMETHING. It does not prove it stored something USABLE. Read it back and
# assert the load-bearing parts are present. The `alertmanager_config: ""` check is not paranoia -
# that exact empty-but-valid response is what a broken tenant serves.
verify_config() {
    local marker
    curl -sf -H "X-Scope-OrgID: ${TENANT}" "${MIMIR_URL}/api/v1/alerts" > "$live_raw" || {
        warn "could not read the config back after posting it"
        return 1
    }

    if grep -q 'alertmanager_config: ""' "$live_raw"; then
        warn "read-back shows an EMPTY config - the load did not take"
        return 1
    fi

    for marker in 'route:' 'receivers:' 'sns-critical' 'sns-warning' 'sns-watchdog'; do
        if ! grep -qF "$marker" "$live_raw"; then
            warn "read-back is missing '${marker}' - the stored config is not the one in git"
            return 1
        fi
    done

    unwrap_body < "$live_raw" > "$posted_body"
    cp "$AM_CONFIG_FILE" "$posted_source"
    log "verified: tenant '${TENANT}' Alertmanager config is live with routes and all three receivers"
}

# The config API takes a WRAPPER document, NOT the raw Alertmanager YAML: the file content goes in as
# a STRING under alertmanager_config. Posting the raw file instead is a silent no-op shaped like a
# success. `jq -Rs` does the escaping, and JSON is valid YAML, which is what the endpoint parses.
apply_config() {
    local code
    jq -Rs '{template_files: {}, alertmanager_config: .}' "$AM_CONFIG_FILE" > "$payload" || {
        warn "failed to build the config payload from $AM_CONFIG_FILE"
        return 1
    }

    log "posting $(wc -c < "$AM_CONFIG_FILE") bytes of Alertmanager config for tenant '${TENANT}'"
    code=$(curl -sS -o /tmp/am-post-body -w '%{http_code}' \
        -X POST \
        -H "X-Scope-OrgID: ${TENANT}" \
        --data-binary "@${payload}" \
        "${MIMIR_URL}/api/v1/alerts") || {
        warn "POST to the Alertmanager config API failed outright"
        return 1
    }

    case "$code" in
        2*) log "config accepted (HTTP ${code})" ;;
        *)  warn "config REJECTED (HTTP ${code}): $(cat /tmp/am-post-body)"; return 1 ;;
    esac

    verify_config
}

# One comparison of live-vs-git, reconciling to git on drift. NEVER exits: a transient Mimir blip
# must not take the loop down, because the loop is what reverts an out-of-band write.
nonconvergent_warned=0
reconcile() {
    if [ ! -s "$AM_CONFIG_FILE" ]; then
        warn "$AM_CONFIG_FILE is missing or empty - refusing to post an empty config"
        return 0
    fi

    curl -sf -H "X-Scope-OrgID: ${TENANT}" "${MIMIR_URL}/api/v1/alerts" > "$live_raw" || {
        warn "could not read the live Alertmanager config - retrying in ${RECONCILE_INTERVAL_SECS}s"
        return 0
    }
    unwrap_body < "$live_raw" > "$live_body"

    if cmp -s "$live_body" "$AM_CONFIG_FILE"; then
        nonconvergent_warned=0
        return 0
    fi

    # Live differs from git, but it is byte-identical to what came back from our own last POST AND
    # the file has not changed since that POST. Nobody overwrote anything - our unwrap round-trip is
    # lossy. Re-posting would loop forever, so say so once and stop.
    #
    # BOTH HALVES ARE LOAD-BEARING. To test only the first swallows every later `git pull`, because
    # after a successful load the live copy always equals what we posted - which is precisely the
    # state a file edit has to be able to interrupt.
    if [ -s "$posted_body" ] && cmp -s "$live_body" "$posted_body" \
        && cmp -s "$AM_CONFIG_FILE" "$posted_source"; then
        if [ "$nonconvergent_warned" -eq 0 ]; then
            warn "live config differs from git but matches what we posted - the API round-trip is lossy, not an out-of-band write; NOT re-posting"
            nonconvergent_warned=1
        fi
        return 0
    fi

    warn "DRIFT: live Alertmanager config ($(wc -c < "$live_body") bytes) differs from git ($(wc -c < "$AM_CONFIG_FILE") bytes) - reconciling to git"
    apply_config || warn "reconcile failed - retrying in ${RECONCILE_INTERVAL_SECS}s"
}

# --- Initial load ----------------------------------------------------------------------------
# Unconditional and hard-failing, unlike the loop. If git's config cannot be loaded at start there is
# nothing to fall back on, and a container that exits non-zero is the loudest available signal.
apply_config || fail "initial Alertmanager config load failed"

if [ "$RECONCILE_INTERVAL_SECS" -le 0 ]; then
    log "RECONCILE_INTERVAL_SECS=${RECONCILE_INTERVAL_SECS} - one-shot mode, exiting"
    exit 0
fi

log "reconciling git -> Mimir every ${RECONCILE_INTERVAL_SECS}s"
while true; do
    sleep "$RECONCILE_INTERVAL_SECS"
    reconcile
done
