#!/bin/bash
# send-test-logs.sh - Send test logs to OTLP HTTP endpoint
#
# Usage:
#   ./send-test-logs.sh [options] [count]
#
# Options:
#   --prod          Use production endpoint (otel-collector.internal.example.com)
#   --endpoint URL  Use custom endpoint URL
#
# Examples:
#   ./send-test-logs.sh                           # localhost, 5 logs
#   ./send-test-logs.sh 10                        # localhost, 10 logs
#   ./send-test-logs.sh --prod 3                  # AWS prod (internal DNS), 3 logs
#   ./send-test-logs.sh --endpoint http://10.0.1.50:4318 3

set -e

# Default values
ENDPOINT="http://localhost:4318"
COUNT=5
SERVICE_NAME="test-log-generator"

# Production endpoint (internal DNS)
PROD_ENDPOINT="http://otel-collector.internal.example.com:4318"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --prod)
            ENDPOINT="${PROD_ENDPOINT}"
            shift
            ;;
        --endpoint)
            ENDPOINT="$2"
            shift 2
            ;;
        *)
            COUNT="$1"
            shift
            ;;
    esac
done

# Generate random hex string for trace/span IDs (for correlation)
generate_trace_id() {
    head -c 16 /dev/urandom | xxd -p | tr -d '\n'
}

generate_span_id() {
    head -c 8 /dev/urandom | xxd -p | tr -d '\n'
}

# Convert to nanoseconds
now_nanos() {
    echo "$(date +%s)000000000"
}

# Severity levels: TRACE=1, DEBUG=5, INFO=9, WARN=13, ERROR=17, FATAL=21
SEVERITIES=("TRACE" "DEBUG" "INFO" "WARN" "ERROR")
SEVERITY_NUMBERS=(1 5 9 13 17)

send_logs() {
    local trace_id
    trace_id=$(generate_trace_id)
    local span_id
    span_id=$(generate_span_id)
    local iteration=$1

    # Build log records array
    local log_records=""
    for i in $(seq 0 $((COUNT - 1))); do
        local timestamp
        timestamp=$(now_nanos)
        local sev_idx
        sev_idx=$((i % 5))
        local severity=${SEVERITIES[$sev_idx]}
        local severity_num=${SEVERITY_NUMBERS[$sev_idx]}

        local message="Test log message #$((i + 1)) from iteration ${iteration} - This is a ${severity} level log"

        if [ -n "$log_records" ]; then
            log_records="${log_records},"
        fi

        log_records="${log_records}
        {
          \"timeUnixNano\": \"${timestamp}\",
          \"severityNumber\": ${severity_num},
          \"severityText\": \"${severity}\",
          \"body\": {\"stringValue\": \"${message}\"},
          \"attributes\": [
            {\"key\": \"log.source\", \"value\": {\"stringValue\": \"test-script\"}},
            {\"key\": \"iteration\", \"value\": {\"intValue\": ${iteration}}},
            {\"key\": \"log.index\", \"value\": {\"intValue\": $((i + 1))}}
          ],
          \"traceId\": \"${trace_id}\",
          \"spanId\": \"${span_id}\"
        }"

        # Small delay between log timestamps
        sleep 0.01
    done

    local payload
    payload=$(cat <<EOF
{
  "resourceLogs": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "${SERVICE_NAME}"}},
        {"key": "service.version", "value": {"stringValue": "1.0.0"}},
        {"key": "deployment.environment", "value": {"stringValue": "test"}},
        {"key": "host.name", "value": {"stringValue": "$(hostname)"}}
      ]
    },
    "scopeLogs": [{
      "scope": {
        "name": "test-logger",
        "version": "1.0.0"
      },
      "logRecords": [${log_records}
      ]
    }]
  }]
}
EOF
)

    echo "Sending ${COUNT} log records (trace_id: ${trace_id:0:16}...)"

    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${ENDPOINT}/v1/logs" \
        -H "Content-Type: application/json" \
        -d "${payload}")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        echo "  Success! Sent ${COUNT} logs with trace correlation"
        echo "  Trace ID: ${trace_id}"
        return 0
    else
        echo "  Failed! HTTP ${http_code}: ${body}"
        return 1
    fi
}

echo "============================================"
echo "OTLP Log Test Sender"
echo "============================================"
echo "Endpoint: ${ENDPOINT}/v1/logs"
echo "Service:  ${SERVICE_NAME}"
echo "Logs per batch: ${COUNT}"
echo "============================================"
echo ""

# Check if endpoint is reachable via health check endpoint (port 13133)
OTLP_HOST=$(echo "${ENDPOINT}" | sed -E 's|https?://([^:/]+).*|\1|')
HEALTH_ENDPOINT="http://${OTLP_HOST}:13133"
echo "Checking OTel Collector health at ${HEALTH_ENDPOINT}..."
if curl -s -f "${HEALTH_ENDPOINT}" > /dev/null 2>&1; then
    echo "OTel Collector is healthy"
else
    echo "Warning: Health check failed at ${HEALTH_ENDPOINT}, attempting to send anyway..."
fi
echo ""

if send_logs 1; then
    echo ""
    echo "============================================"
    echo "Results: Success"
    echo "============================================"
else
    echo ""
    echo "============================================"
    echo "Results: Failed"
    echo "============================================"
    exit 1
fi

echo ""
echo "To view logs in Grafana:"
echo "  1. Open Grafana (http://localhost:3000 or your AWS URL)"
echo "  2. Go to Explore"
echo "  3. Select 'Loki' datasource"
echo "  4. Use LogQL: {service_name=\"${SERVICE_NAME}\"}"
echo "  5. Or filter by severity: {service_name=\"${SERVICE_NAME}\"} |= \"ERROR\""
