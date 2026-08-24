#!/bin/bash
# init-certbot.sh - Initialize Let's Encrypt SSL certificates for Grafana
#
# This script:
# 1. Checks if certificates already exist
# 2. If not, obtains them from Let's Encrypt using webroot authentication
# 3. Generates the SSL-enabled NGINX config from template
# 4. Signals NGINX to reload with SSL configuration
#
# Environment variables:
#   DOMAIN_NAME - The domain name for the certificate (required)
#   CERTBOT_EMAIL - Email for Let's Encrypt notifications (required)
#   STAGING - Set to "1" to use Let's Encrypt staging environment (optional)

set -e

# Configuration
DOMAIN_NAME="${DOMAIN_NAME:-grafana.example.com}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-devops@example.com}"
STAGING="${STAGING:-0}"

CERT_PATH="/etc/letsencrypt/live/${DOMAIN_NAME}"
WEBROOT_PATH="/var/www/certbot"
NGINX_CONF_DIR="/etc/nginx/conf.d"
TEMPLATE_PATH="/etc/nginx/templates/grafana.conf.template"

echo "=== Let's Encrypt Certificate Initialization ==="
echo "Domain: ${DOMAIN_NAME}"
echo "Email: ${CERTBOT_EMAIL}"
echo "Staging: ${STAGING}"

# Create webroot directory if it doesn't exist
mkdir -p "${WEBROOT_PATH}"

# Check if certificates already exist
if [ -f "${CERT_PATH}/fullchain.pem" ] && [ -f "${CERT_PATH}/privkey.pem" ]; then
    echo "Certificates already exist at ${CERT_PATH}"
    echo "Checking certificate validity..."

    # Check if certificate is valid for at least 7 days
    if openssl x509 -checkend 604800 -noout -in "${CERT_PATH}/fullchain.pem" 2>/dev/null; then
        echo "Certificate is valid. Skipping renewal."
    else
        echo "Certificate expires soon. Attempting renewal..."
        certbot renew --webroot -w "${WEBROOT_PATH}" --quiet
    fi
else
    echo "No certificates found. Obtaining new certificate..."

    # Build certbot command
    CERTBOT_CMD="certbot certonly --webroot -w ${WEBROOT_PATH}"
    CERTBOT_CMD="${CERTBOT_CMD} -d ${DOMAIN_NAME}"
    CERTBOT_CMD="${CERTBOT_CMD} --email ${CERTBOT_EMAIL}"
    CERTBOT_CMD="${CERTBOT_CMD} --agree-tos --no-eff-email"
    CERTBOT_CMD="${CERTBOT_CMD} --non-interactive"

    # Use staging environment if requested (for testing)
    if [ "${STAGING}" = "1" ]; then
        echo "Using Let's Encrypt STAGING environment"
        CERTBOT_CMD="${CERTBOT_CMD} --staging"
    fi

    # Run certbot
    echo "Running: ${CERTBOT_CMD}"
    ${CERTBOT_CMD}

    if [ $? -eq 0 ]; then
        echo "Certificate obtained successfully!"
    else
        echo "ERROR: Failed to obtain certificate"
        exit 1
    fi
fi

# Generate SSL-enabled NGINX configuration from template
echo "Generating NGINX SSL configuration..."
if [ -f "${TEMPLATE_PATH}" ]; then
    # Substitute DOMAIN_NAME in template using sed (envsubst may not be available in Alpine)
    sed "s/\${DOMAIN_NAME}/${DOMAIN_NAME}/g" "${TEMPLATE_PATH}" > "${NGINX_CONF_DIR}/grafana.conf"
    echo "SSL configuration generated at ${NGINX_CONF_DIR}/grafana.conf"
else
    echo "WARNING: Template not found at ${TEMPLATE_PATH}"
    echo "Using existing configuration"
fi

# Test NGINX configuration
echo "Testing NGINX configuration..."
nginx -t

if [ $? -eq 0 ]; then
    echo "NGINX configuration is valid"
    # Signal NGINX to reload (if running)
    if pgrep nginx > /dev/null; then
        echo "Reloading NGINX..."
        nginx -s reload
    fi
else
    echo "ERROR: NGINX configuration test failed"
    exit 1
fi

echo "=== SSL initialization complete ==="
echo "Grafana is now available at: https://${DOMAIN_NAME}"
