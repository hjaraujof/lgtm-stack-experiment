# Task: Add SSL to Grafana via NGINX + Let's Encrypt

**Created:** 2025-12-01
**Status:** Completed

## Objective

Enable HTTPS for Grafana on the AWS deployment using NGINX as a reverse proxy with Let's Encrypt certificates. This secures the publicly-accessible Grafana dashboard at `grafana.example.com`.

## Approach

Use a proven reverse-proxy pattern: NGINX container handles SSL termination with certbot for Let's Encrypt certificate management. Grafana remains HTTP internally, NGINX proxies HTTPS traffic to it.

```
Internet → NGINX (443/SSL) → Grafana (3000/HTTP)
```

## Tasks

1. **Create NGINX configuration**
   - SSL termination config for Grafana
   - Proxy pass to `grafana:3000`
   - HTTP → HTTPS redirect
   - Location: `config/nginx/grafana.conf`

2. **Create certbot initialization script**
   - Obtain initial Let's Encrypt certificate
   - Configure auto-renewal via cron
   - Location: `scripts/init-certbot.sh`

3. **Add NGINX + certbot containers to docker-compose.yml**
   - NGINX service with SSL config
   - Certbot service for certificate management
   - Shared volume for certificates
   - Proper service dependencies

4. **Update Terraform security group**
   - Add port 443 (HTTPS) public ingress
   - Add port 80 (HTTP) for ACME challenge & redirect
   - Remove or restrict port 3000 public access

5. **Update user_data.tpl for initial certificate setup**
   - Run certbot on first boot
   - Ensure certificates exist before NGINX starts

6. **Test locally with self-signed certificates (optional)**
   - Verify NGINX proxy works before AWS deployment

7. **Update documentation**
   - CLAUDE.md access information
   - README if exists

8. **Review implementation and capture key facts/learnings to memory**

## File Changes

| File | Action |
|------|--------|
| `config/nginx/grafana.conf` | Create |
| `config/nginx/grafana-ssl.conf` | Create (post-cert) |
| `scripts/init-certbot.sh` | Create |
| `docker-compose.yml` | Modify - add nginx, certbot services |
| `main.tf` | Modify - security group ports |
| `user_data.tpl` | Modify - certbot initialization |
| `.claude/CLAUDE.md` | Modify - update access docs |

## Questions

None at this time - straightforward implementation following an existing reverse-proxy pattern.

## Rollback

If issues arise:
- Revert security group to port 3000 public
- Remove NGINX/certbot containers
- Grafana remains accessible via HTTP as before
