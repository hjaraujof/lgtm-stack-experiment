#!/bin/bash
# send-test-traces.sh - Send test traces to OTLP HTTP endpoint
#
# Usage:
#   ./send-test-traces.sh [options] [count]
#
# Options:
#   --prod          Use production endpoint (otel-collector.internal.example.com)
#   --endpoint URL  Use custom endpoint URL
#
# Examples:
#   ./send-test-traces.sh                           # localhost, 1 trace
#   ./send-test-traces.sh 5                         # localhost, 5 traces
#   ./send-test-traces.sh --prod 3                  # AWS prod (internal DNS), 3 traces
#   ./send-test-traces.sh --endpoint http://10.0.1.50:4318 3

set -e

# Default values
ENDPOINT="http://localhost:4318"
COUNT=1
SERVICE_NAME="test-trace-generator"

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

# Generate random hex string for trace/span IDs
generate_trace_id() {
    # 32 hex chars (16 bytes)
    head -c 16 /dev/urandom | xxd -p | tr -d '\n'
}

generate_span_id() {
    # 16 hex chars (8 bytes)
    head -c 8 /dev/urandom | xxd -p | tr -d '\n'
}

# Convert to nanoseconds
now_nanos() {
    echo "$(date +%s)000000000"
}

send_trace() {
    local trace_id
    trace_id=$(generate_trace_id)
    local parent_span_id
    parent_span_id=$(generate_span_id)
    local child_span_id
    child_span_id=$(generate_span_id)
    local start_time
    start_time=$(now_nanos)
    local end_time
    end_time=$((start_time + 150000000))  # 150ms later
    local child_start
    child_start=$((start_time + 10000000))  # 10ms after parent start
    local child_end
    child_end=$((end_time - 10000000))  # 10ms before parent end

    local iteration=$1
    local operation="test-operation-${iteration}"

    # OTLP JSON format with parent and child spans
    local payload
    payload=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "${SERVICE_NAME}"}},
        {"key": "service.version", "value": {"stringValue": "1.0.0"}},
        {"key": "deployment.environment", "value": {"stringValue": "test"}}
      ]
    },
    "scopeSpans": [{
      "scope": {
        "name": "test-tracer",
        "version": "1.0.0"
      },
      "spans": [
        {
          "traceId": "${trace_id}",
          "spanId": "${parent_span_id}",
          "name": "${operation}",
          "kind": 2,
          "startTimeUnixNano": "${start_time}",
          "endTimeUnixNano": "${end_time}",
          "attributes": [
            {"key": "http.method", "value": {"stringValue": "GET"}},
            {"key": "http.url", "value": {"stringValue": "https://api.example.com/test/${iteration}"}},
            {"key": "http.status_code", "value": {"intValue": 200}},
            {"key": "test.iteration", "value": {"intValue": ${iteration}}}
          ],
          "status": {"code": 1}
        },
        {
          "traceId": "${trace_id}",
          "spanId": "${child_span_id}",
          "parentSpanId": "${parent_span_id}",
          "name": "database-query",
          "kind": 3,
          "startTimeUnixNano": "${child_start}",
          "endTimeUnixNano": "${child_end}",
          "attributes": [
            {"key": "db.system", "value": {"stringValue": "postgresql"}},
            {"key": "db.statement", "value": {"stringValue": "SELECT * FROM users WHERE id = ?"}},
            {"key": "db.name", "value": {"stringValue": "test_db"}}
          ],
          "status": {"code": 1}
        }
      ]
    }]
  }]
}
EOF
)

    echo "Sending trace ${iteration}/${COUNT} (trace_id: ${trace_id:0:16}...)"

    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${ENDPOINT}/v1/traces" \
        -H "Content-Type: application/json" \
        -d "${payload}")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        echo "  Success! Trace ID: ${trace_id}"
    else
        echo "  Failed! HTTP ${http_code}: ${body}"
        return 1
    fi
}

echo "============================================"
echo "OTLP Trace Test Sender"
echo "============================================"
echo "Endpoint: ${ENDPOINT}/v1/traces"
echo "Service:  ${SERVICE_NAME}"
echo "Count:    ${COUNT}"
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

success=0
failed=0

for i in $(seq 1 $COUNT); do
    if send_trace $i; then
        ((success++))
    else
        ((failed++))
    fi

    # Small delay between traces
    if [ $i -lt $COUNT ]; then
        sleep 0.5
    fi
done

echo ""
echo "============================================"
echo "Results: ${success} succeeded, ${failed} failed"
echo "============================================"
echo ""
echo "To view traces in Grafana:"
echo "  1. Open Grafana (http://localhost:3000 or your AWS URL)"
echo "  2. Go to Explore"
echo "  3. Select 'Tempo' datasource"
echo "  4. Search by service name: ${SERVICE_NAME}"
echo "  5. Or use TraceQL: {resource.service.name=\"${SERVICE_NAME}\"}"
