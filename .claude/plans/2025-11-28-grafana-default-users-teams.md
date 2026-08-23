# Task: Grafana Default Users and Teams Configuration

**Created:** 2025-11-28
**Status:** Completed

## Objective

Configure Grafana with:
1. A secure default admin password (not "admin")
2. A "Dev" team that includes the admin account
3. Default developer user accounts added to the Dev team
4. All configuration persists across infrastructure regeneration

## Approach

Use an **init container with Grafana API calls** approach. This is the most robust solution because:
- Grafana provisioning YAML does NOT support users/teams (only datasources, dashboards, alerting)
- API-based approach is idempotent (safe to run multiple times)
- Configuration survives `docker compose down && docker compose up`
- Passwords can be securely managed via `.env` file

### Architecture

```
docker compose up
    ↓
grafana starts → healthcheck passes
    ↓
grafana-init container starts (depends_on: grafana healthy)
    ↓
init-grafana.sh script calls Grafana API:
  1. Create "Dev" team (if not exists)
  2. Create default users (if not exist)
  3. Add admin to "Dev" team
  4. Add all users to "Dev" team
    ↓
grafana-init exits successfully
    ↓
Stack ready
```

## Tasks

1. Create `.env.example` file with template for sensitive values (admin password, user passwords)
2. Create `config/grafana/users-config.json` with team and user definitions
3. Create `scripts/init-grafana.sh` script that:
   - Waits for Grafana API to be ready
   - Creates "Dev" team if not exists
   - Creates default users if not exist
   - Adds admin and users to the Dev team
   - Handles errors gracefully and is idempotent
4. Update `docker-compose.yml`:
   - Add `.env` file reference
   - Update Grafana service to use `${GRAFANA_ADMIN_PASSWORD}` from env
   - Add `grafana-init` service that runs after Grafana is healthy
5. Update `.gitignore` to exclude `.env` (if not already)
6. Update `CLAUDE.md` with documentation about the new configuration
7. Test the full flow: `docker compose down -v && docker compose up -d`
8. Review implementation and capture key learnings to memory

## Configuration Details

### Passwords from AWS Secrets Manager

All passwords fetched from AWS Secrets Manager at path `/example/dev/lgtm-stack`:

| Secret Key | Used For |
|------------|----------|
| `default_grafana_admin_password` | Grafana built-in admin account |
| `default_admin_password` | Dev team users with Admin role |
| `default_member_password` | Dev team users with Editor/Viewer roles |

### Default Users (configurable in users-config.json)

| Login | Name | Role | Team | Password Source |
|-------|------|------|------|-----------------|
| admin | Admin | GrafanaAdmin | Dev | `default_grafana_admin_password` |
| admin-user | Admin User | Admin | Dev | `default_admin_password` |

### Password Behavior

- Passwords are fetched from Secrets Manager on each `grafana-init` run
- If users already exist, their passwords are NOT reset (idempotent)
- To reset a password, delete the user from Grafana UI first

## API Endpoints Used

- `POST /api/admin/users` - Create user
- `GET /api/users/lookup?loginOrEmail=X` - Check if user exists
- `POST /api/teams` - Create team
- `GET /api/teams/search?name=X` - Check if team exists
- `POST /api/teams/:teamId/members` - Add user to team
- `GET /api/teams/:teamId/members` - Check team membership

## References

- [Grafana HTTP API - Admin](https://grafana.com/docs/grafana/latest/developers/http_api/admin/)
- [Grafana HTTP API - Team](https://grafana.com/docs/grafana/latest/developers/http_api/team/)
- [Grafana Provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)

---

## Final Implementation Summary (2025-11-28)

### Files Created/Modified

| File | Purpose |
|------|---------|
| `config/grafana/users-config.json` | Team and user definitions with example team members |
| `scripts/init-grafana.sh` | Idempotent initialization script using Grafana HTTP API |
| `scripts/Dockerfile.grafana-init` | Container image with AWS CLI, jq, curl |
| `docker-compose.yml` | Added `grafana-init` service with health-based dependency |

### Implemented Users

- admin@example.com (Admin)
- admin2@example.com (Admin)
- editor1@example.com (Editor)
- editor2@example.com (Editor)
- editor3@example.com (Editor)

All users added to "Dev" team. Passwords sourced from AWS Secrets Manager at `/example/dev/lgtm-stack`.
