# Task: Add Route 53 DNS Record for LGTM Stack

**Created:** 2025-11-28
**Status:** Completed

## Configuration Decisions

| Setting | Value | Rationale |
|---------|-------|-----------|
| DNS Name | `grafana.example.com` | User preference |
| Elastic IP | No | Use dynamic public IP with short TTL |
| TTL | 300s (5 min) | Good for dev - faster propagation on IP changes |

## Approach

Add a DNS A record under the `example.com` hosted zone that points to the LGTM EC2 instance's public IP. This enables accessing Grafana via `grafana.example.com`.

## Tasks

1. Look up existing `example.com` hosted zone using `data.aws_route53_zone`
2. Create `aws_route53_record` resource for A record pointing to EC2 public IP
3. Add output for the DNS name
4. Run `tofu plan` to verify configuration
5. Review implementation and capture key facts/learnings to memory (with user review)

## Implementation Details

```hcl
# Data source to look up existing hosted zone
data "aws_route53_zone" "example" {
  name         = "example.com"
  private_zone = false
}

# A record pointing to EC2 instance
resource "aws_route53_record" "lgtm_grafana" {
  zone_id = data.aws_route53_zone.example.zone_id
  name    = "grafana.example.com"
  type    = "A"
  ttl     = 300
  records = [aws_instance.lgtm_instance.public_ip]
}

# Output for reference
output "lgtm_dns_name" {
  description = "DNS name for the LGTM Grafana"
  value       = aws_route53_record.lgtm_grafana.fqdn
}
```

---

## Final Implementation Summary (2025-11-28)

### Implementation

Added to `main.tf`:
- `data.aws_route53_zone.example` - Looks up existing hosted zone
- `aws_route53_record.lgtm_grafana` - A record with 300s TTL
- `output.lgtm_dns_name` - Outputs the FQDN

### Result

Grafana accessible at: `https://grafana.example.com`

DNS propagation is fast (~5 min) due to short TTL. No Elastic IP required - uses dynamic EC2 public IP.
