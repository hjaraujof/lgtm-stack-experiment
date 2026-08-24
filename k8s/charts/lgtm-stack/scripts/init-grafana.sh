#!/bin/bash
# Grafana initialization script
# Creates default team and users from AWS Secrets Manager credentials
#
# This script is idempotent - safe to run multiple times.
# Users that already exist will not be modified.

set -e

# Configuration
GRAFANA_URL="${GRAFANA_URL:-http://grafana:3000}"
CONFIG_FILE="${CONFIG_FILE:-/config/users-config.json}"
SECRET_PATH="${SECRET_PATH:-/example/dev/lgtm-stack}"
MAX_RETRIES=30
RETRY_INTERVAL=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Wait for Grafana to be ready
wait_for_grafana() {
    log_info "Waiting for Grafana to be ready..."
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if curl -sf "${GRAFANA_URL}/api/health" > /dev/null 2>&1; then
            log_info "Grafana is ready!"
            return 0
        fi
        retries=$((retries + 1))
        log_info "Grafana not ready yet, retrying in ${RETRY_INTERVAL}s... (${retries}/${MAX_RETRIES})"
        sleep $RETRY_INTERVAL
    done
    log_error "Grafana did not become ready in time"
    return 1
}

# Fetch secrets from environment variables (AWS deployment) or Secrets Manager (local dev)
fetch_secrets() {
    # Check if passwords are provided via environment variables (AWS deployment via user_data)
    if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] && [ -n "${DEFAULT_ADMIN_PASSWORD:-}" ] && [ -n "${DEFAULT_MEMBER_PASSWORD:-}" ]; then
        log_info "Using passwords from environment variables"
        ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD}"
        MEMBER_PASSWORD="${DEFAULT_MEMBER_PASSWORD}"
        # GRAFANA_ADMIN_PASSWORD is already set from env
        log_info "Secrets loaded from environment"
        return 0
    fi

    # Fall back to AWS Secrets Manager (local development with ~/.aws mounted)
    log_info "Environment variables not set, fetching from AWS Secrets Manager: ${SECRET_PATH}"

    SECRETS_JSON=$(aws secretsmanager get-secret-value \
        --secret-id "${SECRET_PATH}" \
        --query 'SecretString' \
        --output text 2>/dev/null) || {
        log_error "Failed to fetch secrets from AWS Secrets Manager"
        return 1
    }

    # Extract password values
    GRAFANA_ADMIN_PASSWORD=$(echo "${SECRETS_JSON}" | jq -r '.default_grafana_admin_password // empty')
    ADMIN_PASSWORD=$(echo "${SECRETS_JSON}" | jq -r '.default_admin_password // empty')
    MEMBER_PASSWORD=$(echo "${SECRETS_JSON}" | jq -r '.default_member_password // empty')

    if [ -z "${GRAFANA_ADMIN_PASSWORD}" ]; then
        log_error "default_grafana_admin_password not found in secrets"
        return 1
    fi

    if [ -z "${ADMIN_PASSWORD}" ]; then
        log_error "default_admin_password not found in secrets"
        return 1
    fi

    if [ -z "${MEMBER_PASSWORD}" ]; then
        log_error "default_member_password not found in secrets"
        return 1
    fi

    log_info "Secrets fetched successfully from Secrets Manager"
}

# Update Grafana admin password
update_admin_password() {
    log_info "Updating Grafana admin password..."

    # Try with default password first, then with the target password (already set)
    local response
    response=$(curl -sf -X PUT "${GRAFANA_URL}/api/admin/users/1/password" \
        -H "Content-Type: application/json" \
        -u "admin:admin" \
        -d "{\"password\": \"${GRAFANA_ADMIN_PASSWORD}\"}" 2>/dev/null) && {
        log_info "Admin password updated successfully"
        return 0
    }

    # Check if password was already changed
    response=$(curl -sf "${GRAFANA_URL}/api/org" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" 2>/dev/null) && {
        log_info "Admin password already set correctly"
        return 0
    }

    log_error "Failed to update admin password"
    return 1
}

# Create a team if it doesn't exist
create_team() {
    local team_name="$1"
    local team_email="$2"

    log_info "Creating team: ${team_name}"

    # Check if team exists
    local existing_team
    existing_team=$(curl -sf "${GRAFANA_URL}/api/teams/search?name=${team_name}" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" 2>/dev/null)

    local team_count
    team_count=$(echo "${existing_team}" | jq -r '.totalCount // 0')

    if [ "${team_count}" -gt 0 ]; then
        TEAM_ID=$(echo "${existing_team}" | jq -r '.teams[0].id')
        log_info "Team '${team_name}' already exists with ID: ${TEAM_ID}"
        return 0
    fi

    # Create team
    local response
    response=$(curl -sf -X POST "${GRAFANA_URL}/api/teams" \
        -H "Content-Type: application/json" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        -d "{\"name\": \"${team_name}\", \"email\": \"${team_email}\"}" 2>/dev/null)

    TEAM_ID=$(echo "${response}" | jq -r '.teamId // empty')

    if [ -n "${TEAM_ID}" ]; then
        log_info "Team '${team_name}' created with ID: ${TEAM_ID}"
        return 0
    fi

    log_error "Failed to create team '${team_name}'"
    return 1
}

# Create a user if they don't exist
create_user() {
    local login="$1"
    local name="$2"
    local email="$3"
    local role="$4"
    local password="$5"

    log_info "Creating user: ${login} (${role})"

    # Check if user exists
    local existing_user
    existing_user=$(curl -sf "${GRAFANA_URL}/api/users/lookup?loginOrEmail=${login}" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" 2>/dev/null)

    local user_id
    user_id=$(echo "${existing_user}" | jq -r '.id // empty')

    if [ -n "${user_id}" ]; then
        log_info "User '${login}' already exists with ID: ${user_id}"
        echo "${user_id}"
        return 0
    fi

    # Create user
    local response
    response=$(curl -sf -X POST "${GRAFANA_URL}/api/admin/users" \
        -H "Content-Type: application/json" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        -d "{
            \"name\": \"${name}\",
            \"login\": \"${login}\",
            \"email\": \"${email}\",
            \"password\": \"${password}\",
            \"OrgId\": 1
        }" 2>/dev/null)

    user_id=$(echo "${response}" | jq -r '.id // empty')

    if [ -n "${user_id}" ]; then
        log_info "User '${login}' created with ID: ${user_id}"

        # Update user's org role if not Viewer (default)
        if [ "${role}" != "Viewer" ]; then
            curl -sf -X PATCH "${GRAFANA_URL}/api/org/users/${user_id}" \
                -H "Content-Type: application/json" \
                -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
                -d "{\"role\": \"${role}\"}" > /dev/null 2>&1
            log_info "User '${login}' role set to ${role}"
        fi

        echo "${user_id}"
        return 0
    fi

    log_error "Failed to create user '${login}'"
    return 1
}

# Add user to team
add_user_to_team() {
    local team_id="$1"
    local user_id="$2"
    local login="$3"

    # Check if user is already in team
    local members
    members=$(curl -sf "${GRAFANA_URL}/api/teams/${team_id}/members" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" 2>/dev/null)

    local is_member
    is_member=$(echo "${members}" | jq -r ".[] | select(.userId == ${user_id}) | .userId // empty")

    if [ -n "${is_member}" ]; then
        log_info "User '${login}' is already a member of team"
        return 0
    fi

    # Add user to team
    local response
    response=$(curl -sf -X POST "${GRAFANA_URL}/api/teams/${team_id}/members" \
        -H "Content-Type: application/json" \
        -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        -d "{\"userId\": ${user_id}}" 2>/dev/null)

    if [ $? -eq 0 ]; then
        log_info "User '${login}' added to team"
        return 0
    fi

    log_warn "Could not add user '${login}' to team (may already be a member)"
    return 0
}

# Add admin user to team
add_admin_to_team() {
    local team_id="$1"

    log_info "Adding admin user to team..."
    add_user_to_team "${team_id}" "1" "admin"
}

# Main execution
main() {
    log_info "Starting Grafana initialization..."
    log_info "Config file: ${CONFIG_FILE}"
    log_info "Secrets path: ${SECRET_PATH}"

    # Check if config file exists
    if [ ! -f "${CONFIG_FILE}" ]; then
        log_error "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi

    # Wait for Grafana
    wait_for_grafana || exit 1

    # Fetch secrets
    fetch_secrets || exit 1

    # Update admin password
    update_admin_password || exit 1

    # Read team config
    local team_name
    local team_email
    team_name=$(jq -r '.team.name' "${CONFIG_FILE}")
    team_email=$(jq -r '.team.email' "${CONFIG_FILE}")

    # Create team
    create_team "${team_name}" "${team_email}" || exit 1

    # Add admin to team
    add_admin_to_team "${TEAM_ID}"

    # Create users and add to team
    local user_count
    user_count=$(jq -r '.users | length' "${CONFIG_FILE}")

    for i in $(seq 0 $((user_count - 1))); do
        local login name email role password_key password

        login=$(jq -r ".users[$i].login" "${CONFIG_FILE}")
        name=$(jq -r ".users[$i].name" "${CONFIG_FILE}")
        email=$(jq -r ".users[$i].email" "${CONFIG_FILE}")
        role=$(jq -r ".users[$i].role" "${CONFIG_FILE}")
        password_key=$(jq -r ".users[$i].passwordKey" "${CONFIG_FILE}")

        # Get password based on key
        case "${password_key}" in
            "default_admin_password")
                password="${ADMIN_PASSWORD}"
                ;;
            "default_member_password")
                password="${MEMBER_PASSWORD}"
                ;;
            *)
                log_error "Unknown password key: ${password_key}"
                continue
                ;;
        esac

        # Map "Member" role to Grafana's "Editor" role
        if [ "${role}" = "Member" ]; then
            role="Editor"
        fi

        user_id=$(create_user "${login}" "${name}" "${email}" "${role}" "${password}")

        if [ -n "${user_id}" ]; then
            add_user_to_team "${TEAM_ID}" "${user_id}" "${login}"
        fi
    done

    log_info "=========================================="
    log_info "Grafana initialization completed!"
    log_info "=========================================="
    log_info "Team: ${team_name}"
    log_info "Users created: ${user_count}"
    log_info "Grafana URL: ${GRAFANA_URL}"
    log_info "=========================================="
}

main "$@"
