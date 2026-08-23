#!/bin/bash
# renew-certs.sh - Renew Let's Encrypt certificates and reload NGINX
#
# This script is designed to run periodically (e.g., via cron or Docker healthcheck)
# It will only renew certificates if they're due for renewal (within 30 days of expiry)

set -e

echo "[$(date)] Checking certificate renewal..."

# Attempt renewal (certbot only renews if needed)
# The deploy-hook runs inside this container after a successful renewal.
# Since nginx runs in a sibling container, we reload it via the Docker socket
# (mounted into this container) using the docker CLI.
certbot renew --webroot -w /var/www/certbot --quiet --deploy-hook "docker exec nginx nginx -s reload"

echo "[$(date)] Certificate check complete"
