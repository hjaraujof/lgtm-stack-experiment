#!/bin/bash
# send-test-telemetry.sh - Send test data to all OTLP pipelines (traces, logs, metrics)
#
# Usage:
#   ./send-test-telemetry.sh [options]
#
# Options:
#   --prod          Use production endpoint (otel-collector.internal.example.com) - run from within VPC
#   --ssh           SSH into EC2 and run test there (for testing from outside VPC)
#   --endpoint URL  Use custom endpoint URL
#
# Examples:
#   ./send-test-telemetry.sh                      # localhost (local docker stack)
#   ./send-test-telemetry.sh --prod               # AWS prod (must be within VPC)
#   ./send-test-telemetry.sh --ssh                # SSH to EC2 and test from there
#   ./send-test-telemetry.sh --endpoint http://10.0.1.50:4318

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
ENDPOINT="http://localhost:4318"
ENDPOINT_ARG=""
USE_SSH=false

# Production endpoint (internal DNS - only works within VPC)
PROD_ENDPOINT="http://otel-collector.internal.example.com:4318"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --prod)
            ENDPOINT="${PROD_ENDPOINT}"
            ENDPOINT_ARG="--endpoint ${ENDPOINT}"
            shift
            ;;
        --ssh)
            USE_SSH=true
            shift
            ;;
        --endpoint)
            ENDPOINT="$2"
            ENDPOINT_ARG="--endpoint ${ENDPOINT}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# If --ssh flag, connect to EC2 and run test remotely
if [ "$USE_SSH" = true ]; then
    echo "Fetching EC2 public IP from AWS Secrets Manager..."
    EC2_IP=$(aws secretsmanager get-secret-value --secret-id /example/dev/lgtm-stack --query 'SecretString' --output text | jq -r '.ec2_public_ip')

    if [ -z "$EC2_IP" ] || [ "$EC2_IP" = "null" ]; then
        echo "Error: Could not fetch EC2 public IP from Secrets Manager"
        echo "Make sure 'ec2_public_ip' is set in /example/dev/lgtm-stack"
        exit 1
    fi

    echo "Connecting to EC2 at ${EC2_IP} and running test..."
    echo ""

    # Run the test script on the EC2 instance using localhost (collector runs there)
    ssh -o StrictHostKeyChecking=no "ec2-user@${EC2_IP}" 'cd ~/lgtm_stack && ./scripts/send-test-telemetry.sh'
    exit $?
fi

echo "============================================"
echo "OTLP Full Telemetry Test"
echo "============================================"
echo "Endpoint: ${ENDPOINT}"
echo "============================================"
echo ""

# Check endpoint health first
# Health check is on port 13133, extract host from OTLP endpoint
OTLP_HOST=$(echo "${ENDPOINT}" | sed -E 's|https?://([^:/]+).*|\1|')
HEALTH_ENDPOINT="http://${OTLP_HOST}:13133"
echo "Checking OTel Collector health at ${HEALTH_ENDPOINT}..."
if curl -s -f "${HEALTH_ENDPOINT}" > /dev/null 2>&1; then
    echo "OTel Collector health check passed"
else
    echo "Warning: Health endpoint not responding at ${HEALTH_ENDPOINT}, continuing anyway..."
fi
echo ""

echo "========================================"
echo "1. SENDING TEST TRACES"
echo "========================================"
"${SCRIPT_DIR}/send-test-traces.sh" ${ENDPOINT_ARG} 3
echo ""

echo "========================================"
echo "2. SENDING TEST LOGS"
echo "========================================"
"${SCRIPT_DIR}/send-test-logs.sh" ${ENDPOINT_ARG} 10
echo ""

echo "========================================"
echo "3. SENDING TEST METRICS"
echo "========================================"
"${SCRIPT_DIR}/send-test-metrics.sh" ${ENDPOINT_ARG} 3
echo ""

echo "============================================"
echo "ALL TELEMETRY SENT SUCCESSFULLY"
echo "============================================"
echo ""
echo "View your data in Grafana:"
echo ""
echo "TRACES (Tempo):"
echo "  - Datasource: Tempo"
echo "  - TraceQL: {resource.service.name=\"test-trace-generator\"}"
echo ""
echo "LOGS (Loki):"
echo "  - Datasource: Loki"
echo "  - LogQL: {service_name=\"test-log-generator\"}"
echo ""
echo "METRICS (Mimir):"
echo "  - Datasource: Mimir"
echo "  - PromQL: http_requests_total{service_name=\"test-metric-generator\"}"
echo ""
