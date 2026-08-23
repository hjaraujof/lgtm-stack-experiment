# Task: Pass Grafana Secrets via Terraform User Data

**Created:** 2025-11-28
**Status:** Completed

## Problem

The `grafana-init` container can't run on AWS because:
- It mounts `~/.aws` for credentials, which doesn't exist on EC2
- Without credentials, it can't fetch passwords from Secrets Manager
- Result: Users/teams aren't created, admin password stays as default `admin`

## Solution

Pass secrets from Terraform (which already has access) through `user_data.tpl` as environment variables. The init script will use env vars if available, falling back to Secrets Manager for local dev.

## Tasks

1. Update `main.tf` - pass password secrets to user_data template
2. Update `user_data.tpl` - create `.env` file with passwords before docker-compose starts
3. Update `docker-compose.yml` - pass env vars to grafana-init container
4. Update `init-grafana.sh` - use env vars if set, otherwise fetch from Secrets Manager
5. Run `tofu plan` to verify
6. Review implementation and capture key learnings to memory

## Implementation Details

### 1. main.tf - Add secrets to templatefile call

```hcl
user_data = templatefile("${path.module}/user_data.tpl", {
  git_access_key             = local.secrets.git_access_key
  git_repo_url               = local.secrets.git_repo_url
  grafana_admin_password     = local.secrets.default_grafana_admin_password
  default_admin_password     = local.secrets.default_admin_password
  default_member_password    = local.secrets.default_member_password
})
```

### 2. user_data.tpl - Create .env file before docker-compose

```bash
# Create .env file with Grafana secrets (before docker-compose up)
cat > /home/ec2-user/lgtm_stack/.env <<'ENVEOF'
GRAFANA_ADMIN_PASSWORD=${grafana_admin_password}
DEFAULT_ADMIN_PASSWORD=${default_admin_password}
DEFAULT_MEMBER_PASSWORD=${default_member_password}
ENVEOF
chown ec2-user:ec2-user /home/ec2-user/lgtm_stack/.env
chmod 600 /home/ec2-user/lgtm_stack/.env
```

### 3. docker-compose.yml - Pass env vars to grafana-init

```yaml
grafana-init:
  environment:
    - GRAFANA_URL=http://grafana:3000
    - CONFIG_FILE=/config/users-config.json
    - SECRET_PATH=/example/dev/lgtm-stack
    - GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:-}
    - DEFAULT_ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD:-}
    - DEFAULT_MEMBER_PASSWORD=${DEFAULT_MEMBER_PASSWORD:-}
```

### 4. init-grafana.sh - Use env vars if available

```bash
fetch_secrets() {
    # Check if passwords are provided via environment variables (AWS deployment)
    if [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] && [ -n "${DEFAULT_ADMIN_PASSWORD:-}" ] && [ -n "${DEFAULT_MEMBER_PASSWORD:-}" ]; then
        log_info "Using passwords from environment variables"
        ADMIN_PASSWORD="${DEFAULT_ADMIN_PASSWORD}"
        MEMBER_PASSWORD="${DEFAULT_MEMBER_PASSWORD}"
        # GRAFANA_ADMIN_PASSWORD already set
        return 0
    fi

    # Fall back to Secrets Manager (local development)
    log_info "Fetching secrets from AWS Secrets Manager: ${SECRET_PATH}"
    # ... existing Secrets Manager logic ...
}
```

## Benefits

- No IAM instance profile needed
- Simpler infrastructure
- Local dev still works (falls back to Secrets Manager)
- Secrets are injected at deploy time, not runtime

---

## Final Implementation Summary (2025-11-28)

### Files Modified

| File | Changes |
|------|---------|
| `main.tf` | Added `grafana_admin_password`, `default_admin_password`, `default_member_password` to templatefile call |
| `user_data.tpl` | Creates `.env` file with secrets before `docker-compose up` |
| `docker-compose.yml` | Passes env vars to `grafana-init` container |
| `scripts/init-grafana.sh` | Uses env vars if available, falls back to Secrets Manager |

### Verification

- AWS deployment: Secrets injected via Terraform -> user_data -> .env file
- Local development: Falls back to Secrets Manager via `~/.aws` credentials
- Both paths tested and working
