#!/usr/bin/env bash
#
# Render the NGINX server config for this deployment's domain and reload nginx.
#
# WHY THIS EXISTS. The SSL switch used to be a `docker exec nginx sh -c 'sed ...
# > /etc/nginx/conf.d/grafana.conf'`. That had two defects. It ran inside the
# container, so a container recreate reverted it and SSL silently fell back to
# HTTP. And conf.d/grafana.conf was a single-file bind mount of a tracked repo
# file, so the redirect wrote THROUGH the mount and modified version-controlled
# source at runtime.
#
# Now conf.d is a host DIRECTORY bind-mounted into the container, this script
# renders into it from the host, and the result survives a recreate.
#
# Usage:
#   scripts/render-nginx-ssl.sh init          # HTTP-only, for the ACME challenge
#   scripts/render-nginx-ssl.sh ssl <domain>  # HTTPS, after certbot succeeds
#
# `init` takes no domain: the pre-certificate config serves the ACME webroot on
# port 80 for any host, and naming a domain there would only mislead.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CONF_D="$REPO_ROOT/config/nginx/conf.d"
readonly TEMPLATE="$REPO_ROOT/config/nginx/grafana.conf.template"
readonly INIT_CONF="$REPO_ROOT/config/nginx/grafana-init.conf"
readonly TARGET="$CONF_D/grafana.conf"

usage() {
    echo "usage: $0 init | $0 ssl <domain>" >&2
    exit 2
}

reload_nginx() {
    # Test before reload. An invalid config that nginx has already loaded is a
    # worse position than one it refused: the running server keeps serving the
    # OLD config and the operator believes the new one is live.
    if ! docker exec nginx nginx -t; then
        echo "ERROR: nginx rejected the rendered config; NOT reloading." >&2
        echo "       The previous config is still live. Fix $TARGET and rerun." >&2
        return 1
    fi
    docker exec nginx nginx -s reload
    echo "OK: nginx reloaded with $TARGET"
}

main() {
    local mode="${1:-}"
    mkdir -p "$CONF_D"

    case "$mode" in
        init)
            [ $# -eq 1 ] || usage
            cp "$INIT_CONF" "$TARGET"
            echo "OK: rendered HTTP-only config to $TARGET"
            ;;
        ssl)
            [ $# -eq 2 ] || usage
            local domain="$2"
            [ -n "$domain" ] || { echo "ERROR: empty domain" >&2; exit 1; }
            # `|` as the sed delimiter, because a domain never contains one and
            # the replacement is not escaped.
            sed "s|\${DOMAIN_NAME}|$domain|g" "$TEMPLATE" > "$TARGET"
            if grep -q '\${DOMAIN_NAME}' "$TARGET"; then
                echo "ERROR: DOMAIN_NAME placeholder survived the render." >&2
                exit 1
            fi
            echo "OK: rendered SSL config for $domain to $TARGET"
            ;;
        *)
            usage
            ;;
    esac

    # Only reload if nginx is actually up. During first boot this script runs
    # before compose starts, and a missing container is not an error there.
    if docker ps --format '{{.Names}}' | grep -qx nginx; then
        reload_nginx
    else
        echo "note: nginx container is not running; config will be read on start."
    fi
}

main "$@"
