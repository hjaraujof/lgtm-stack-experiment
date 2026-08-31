#!/bin/bash
# send-test-metrics.sh - Send test metrics to OTLP HTTP endpoint
#
# Usage:
#   ./send-test-metrics.sh [options] [count]
#
# Options:
#   --prod          Use production endpoint (otel-collector.internal.example.com)
#   --endpoint URL  Use custom endpoint URL
#
# Examples:
#   ./send-test-metrics.sh                           # localhost, 5 data points
#   ./send-test-metrics.sh 10                        # localhost, 10 data points
#   ./send-test-metrics.sh --prod 3                  # AWS prod (internal DNS), 3 data points
#   ./send-test-metrics.sh --endpoint http://10.0.1.50:4318 3

set -e

# Default values
ENDPOINT="http://localhost:4318"
COUNT=5
SERVICE_NAME="test-metric-generator"

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

# Convert to nanoseconds
now_nanos() {
    echo "$(date +%s)000000000"
}

send_metrics() {
    local timestamp
    timestamp=$(now_nanos)
    local iteration=$1

    # Generate some realistic-ish metric values
    local request_count
    request_count=$((RANDOM % 1000 + 100))
    local request_duration
    request_duration=$((RANDOM % 500 + 50))
    # THESE TWO ARE FORMATTED WITH printf, NOT COMPUTED WITH bc, AND THE REASON IS THAT
    # THE OUTPUT LANDS INSIDE JSON.
    #
    # `echo "scale=2; 4 / 100" | bc` prints `.04`. GNU bc omits the leading zero, and a
    # leading-dot number IS NOT VALID JSON. RANDOM % 10 is always 0-9, so the value was
    # always below 1, so this was always emitted in the invalid form and the collector
    # always answered:
    #   HTTP 400 ReadUint64: unsupported value type ... "asDouble": .04
    # The script prints `Failed!` and continues, which is why it went unnoticed.
    #
    # The second failure is worse and quieter: bc is NOT INSTALLED on many machines,
    # including a plain NixOS host. Then the substitution yields an EMPTY STRING and the
    # payload becomes `"asDouble": ,` - still a 400, from a completely different cause.
    #
    # printf needs no external program and cannot produce either shape.
    local error_rate
    error_rate=$(printf '0.%02d' $((RANDOM % 10)))
    local active_connections
    active_connections=$((RANDOM % 50 + 5))
    local cpu_usage
    cpu_usage=$(printf '%d.00' $((RANDOM % 80 + 10)))

    local payload
    payload=$(cat <<EOF
{
  "resourceMetrics": [{
    "resource": {
      "attributes": [
        {"key": "service.name", "value": {"stringValue": "${SERVICE_NAME}"}},
        {"key": "service.version", "value": {"stringValue": "1.0.0"}},
        {"key": "deployment.environment", "value": {"stringValue": "test"}},
        {"key": "host.name", "value": {"stringValue": "$(hostname)"}}
      ]
    },
    "scopeMetrics": [{
      "scope": {
        "name": "test-meter",
        "version": "1.0.0"
      },
      "metrics": [
        {
          "name": "http_requests_total",
          "description": "Total number of HTTP requests",
          "unit": "1",
          "sum": {
            "dataPoints": [{
              "asInt": "${request_count}",
              "startTimeUnixNano": "${timestamp}",
              "timeUnixNano": "${timestamp}",
              "attributes": [
                {"key": "http.method", "value": {"stringValue": "GET"}},
                {"key": "http.status_code", "value": {"stringValue": "200"}},
                {"key": "iteration", "value": {"intValue": ${iteration}}}
              ]
            }],
            "aggregationTemporality": 2,
            "isMonotonic": true
          }
        },
        {
          "name": "http_request_duration_ms",
          "description": "HTTP request duration in milliseconds",
          "unit": "ms",
          "gauge": {
            "dataPoints": [{
              "asDouble": ${request_duration}.5,
              "timeUnixNano": "${timestamp}",
              "attributes": [
                {"key": "http.method", "value": {"stringValue": "GET"}},
                {"key": "http.route", "value": {"stringValue": "/api/test"}},
                {"key": "iteration", "value": {"intValue": ${iteration}}}
              ]
            }]
          }
        },
        {
          "name": "error_rate",
          "description": "Error rate as a ratio",
          "unit": "1",
          "gauge": {
            "dataPoints": [{
              "asDouble": ${error_rate},
              "timeUnixNano": "${timestamp}",
              "attributes": [
                {"key": "iteration", "value": {"intValue": ${iteration}}}
              ]
            }]
          }
        },
        {
          "name": "active_connections",
          "description": "Number of active connections",
          "unit": "1",
          "gauge": {
            "dataPoints": [{
              "asInt": "${active_connections}",
              "timeUnixNano": "${timestamp}",
              "attributes": [
                {"key": "connection.type", "value": {"stringValue": "http"}},
                {"key": "iteration", "value": {"intValue": ${iteration}}}
              ]
            }]
          }
        },
        {
          "name": "system_cpu_usage",
          "description": "CPU usage percentage",
          "unit": "%",
          "gauge": {
            "dataPoints": [{
              "asDouble": ${cpu_usage},
              "timeUnixNano": "${timestamp}",
              "attributes": [
                {"key": "cpu.core", "value": {"stringValue": "total"}},
                {"key": "iteration", "value": {"intValue": ${iteration}}}
              ]
            }]
          }
        }
      ]
    }]
  }]
}
EOF
)

    echo "Sending metrics batch ${iteration}/${COUNT}"
    echo "  - http_requests_total: ${request_count}"
    echo "  - http_request_duration_ms: ${request_duration}.5ms"
    echo "  - error_rate: ${error_rate}"
    echo "  - active_connections: ${active_connections}"
    echo "  - system_cpu_usage: ${cpu_usage}%"

    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${ENDPOINT}/v1/metrics" \
        -H "Content-Type: application/json" \
        -d "${payload}")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        echo "  Success!"
        return 0
    else
        echo "  Failed! HTTP ${http_code}: ${body}"
        return 1
    fi
}

echo "============================================"
echo "OTLP Metrics Test Sender"
echo "============================================"
echo "Endpoint: ${ENDPOINT}/v1/metrics"
echo "Service:  ${SERVICE_NAME}"
echo "Batches:  ${COUNT}"
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
    echo ""
    if send_metrics $i; then
        # `$(( ))`, NOT `(( ))`. THE SCRIPT RUNS UNDER `set -e` (line 17), AND
        # `((success++))` EXITS IT.
        #
        # A `(( ))` command's exit status is 0 when the expression is NON-ZERO and 1 when
        # it is zero. Post-increment evaluates to the OLD value, so the FIRST
        # `((success++))` - when success is still 0 - returns 1, and `set -e` treats that
        # as a failed command and terminates the script.
        #
        # The effect: the loop always stopped after the first batch, whichever branch it
        # took, and the summary below never printed. It looked like the send had hung.
        success=$((success + 1))
    else
        failed=$((failed + 1))
    fi

    # Delay between batches for time-series data
    if [ $i -lt $COUNT ]; then
        echo "  Waiting 2 seconds before next batch..."
        sleep 2
    fi
done

echo ""
echo "============================================"
echo "Results: ${success} succeeded, ${failed} failed"
echo "============================================"
echo ""
echo "To view metrics in Grafana:"
echo "  1. Open Grafana (http://localhost:3000 or your AWS URL)"
echo "  2. Go to Explore"
echo "  3. Select 'Mimir' datasource"
echo "  4. Use PromQL queries like:"
echo "     - http_requests_total{service_name=\"${SERVICE_NAME}\"}"
echo "     - http_request_duration_ms{service_name=\"${SERVICE_NAME}\"}"
echo "     - rate(http_requests_total[5m])"
echo "     - avg(system_cpu_usage)"
