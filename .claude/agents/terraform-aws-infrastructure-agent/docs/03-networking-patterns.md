# Networking Patterns

## Overview

This document covers AWS VPC networking patterns, subnet selection strategies, NAT gateway usage, and load balancer integration patterns for Terraform-managed infrastructure.

---

## VPC and Subnet Fundamentals

### Current Configuration Analysis

```hcl
# Uses existing VPC (managed externally)
data "aws_vpc" "example_connect_target_vpc" {
  id = local.secrets.vpc_id
}

# Selects public subnet by tags
data "aws_subnet" "public_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.example_connect_target_vpc.id]
  }
  filter {
    name   = "tag:Client"
    values = ["example"]
  }
  filter {
    name   = "tag:Name"
    values = ["example"]
  }
}

# Instance deployed in public subnet with public IP
resource "aws_instance" "lgtm_instance" {
  # ...
  subnet_id                   = data.aws_subnet.public_subnet.id
  associate_public_ip_address = true
}
```

**Current Architecture:**
- ✅ Uses data sources for existing VPC (good - VPC managed separately)
- ✅ Tag-based subnet selection (flexible)
- ⚠️ Single subnet (no multi-AZ for HA)
- ⚠️ Public subnet with public IP (security consideration)
- ⚠️ No NAT gateway or load balancer configuration

---

## Public vs Private Subnet Patterns

### Definitions

**Public Subnet:**
- Has a route to an Internet Gateway (IGW)
- Resources can have public IP addresses
- Directly accessible from the internet
- Use for: Load balancers, bastion hosts, NAT gateways

**Private Subnet:**
- No direct route to Internet Gateway
- Routes internet-bound traffic through NAT Gateway
- Resources not directly accessible from internet
- Use for: Application servers, databases, internal services

### When to Use Each

**Use Public Subnet When:**
- Service needs to be publicly accessible (e.g., Grafana dashboard)
- Acting as a jump host or bastion
- Running NAT gateway or load balancer
- Development/testing environments

**Use Private Subnet When:**
- Backend services (e.g., Loki, Tempo, Mimir)
- Database instances
- Internal applications
- Production environments (security best practice)

---

## Subnet Selection Patterns

### Pattern 1: Query by Tag (Current Approach)

```hcl
# Select subnet by tags
data "aws_subnet" "public_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.example_connect_target_vpc.id]
  }
  filter {
    name   = "tag:Name"
    values = ["example-public-1a"]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
}
```

**Pros:**
- Flexible - works with existing infrastructure
- Human-readable
- Easy to understand

**Cons:**
- Depends on consistent tagging
- Can fail if tags change
- Returns only one subnet

### Pattern 2: Query by ID (Most Reliable)

```hcl
# Use subnet ID from configuration
data "aws_subnet" "public_subnet" {
  id = local.secrets.public_subnet_id
}
```

**Pros:**
- Most reliable - IDs don't change
- Fastest lookup
- No ambiguity

**Cons:**
- Less flexible
- Requires knowing subnet IDs upfront

### Pattern 3: Query Multiple Subnets

```hcl
# Get all public subnets in VPC
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.example_connect_target_vpc.id]
  }
  filter {
    name   = "tag:Type"
    values = ["public"]
  }
}

# Get subnet details for each
data "aws_subnet" "public_subnet_details" {
  for_each = toset(data.aws_subnets.public.ids)
  id       = each.value
}

# Use all subnets for high availability
resource "aws_lb" "grafana" {
  # ...
  subnets = data.aws_subnets.public.ids
}
```

**Pros:**
- Supports multi-AZ deployments
- No hardcoded subnet IDs
- Good for load balancers and ASGs

**Cons:**
- More complex
- Requires consistent tagging

### Pattern 4: Select by Availability Zone

```hcl
# Get one subnet per AZ
data "aws_subnet" "public_1a" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.example_connect_target_vpc.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a"]
  }
  filter {
    name   = "tag:Type"
    values = ["public"]
  }
}

data "aws_subnet" "public_1b" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.example_connect_target_vpc.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1b"]
  }
  filter {
    name   = "tag:Type"
    values = ["public"]
  }
}

# Deploy across multiple AZs
resource "aws_autoscaling_group" "lgtm" {
  # ...
  vpc_zone_identifier = [
    data.aws_subnet.public_1a.id,
    data.aws_subnet.public_1b.id
  ]
}
```

---

## NAT Gateway Patterns

### What is a NAT Gateway?

NAT Gateway allows instances in private subnets to:
- Access the internet for updates
- Make outbound API calls
- Download packages and dependencies

But prevents:
- Inbound connections from the internet
- Direct public access to instances

### Pattern 1: Single NAT Gateway (Cost-Optimized)

**For development/non-critical workloads:**

```hcl
# Elastic IP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "lgtm-nat-eip"
  }
}

# NAT Gateway in public subnet
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = data.aws_subnet.public_subnet.id

  tags = {
    Name = "lgtm-nat-gateway"
  }

  depends_on = [data.aws_internet_gateway.main]
}

# Route table for private subnet
resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.example_connect_target_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "lgtm-private-rt"
  }
}

# Associate private subnet with route table
resource "aws_route_table_association" "private" {
  subnet_id      = data.aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private.id
}
```

**Costs:**
- NAT Gateway: ~$0.045/hour (~$32/month)
- Data processing: $0.045/GB
- **Total**: ~$35-50/month for low traffic

**Pros:**
- Simple architecture
- Lower cost
- Sufficient for dev/test

**Cons:**
- Single point of failure
- No high availability
- All traffic goes through one AZ

### Pattern 2: Multi-AZ NAT Gateway (High Availability)

**For production workloads:**

```hcl
# Get availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Get public subnets (one per AZ)
data "aws_subnet" "public" {
  for_each = toset(data.aws_availability_zones.available.names)

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.example_connect_target_vpc.id]
  }
  filter {
    name   = "availability-zone"
    values = [each.value]
  }
  filter {
    name   = "tag:Type"
    values = ["public"]
  }
}

# Elastic IP for each NAT Gateway
resource "aws_eip" "nat" {
  for_each = data.aws_subnet.public

  domain = "vpc"

  tags = {
    Name = "lgtm-nat-eip-${each.key}"
  }
}

# NAT Gateway in each public subnet
resource "aws_nat_gateway" "main" {
  for_each = data.aws_subnet.public

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = each.value.id

  tags = {
    Name = "lgtm-nat-gateway-${each.key}"
  }
}

# Route table for each private subnet
resource "aws_route_table" "private" {
  for_each = data.aws_subnet.public

  vpc_id = data.aws_vpc.example_connect_target_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[each.key].id
  }

  tags = {
    Name = "lgtm-private-rt-${each.key}"
  }
}
```

**Costs:**
- NAT Gateway x3: ~$0.045/hour x3 (~$96/month)
- Data processing: $0.045/GB x3
- **Total**: ~$100-150/month

**Pros:**
- High availability
- No single point of failure
- Better performance (reduced cross-AZ traffic)

**Cons:**
- Higher cost (3x NAT gateway charges)
- More complex configuration

### Pattern 3: NAT Instance (Cost-Optimized Alternative)

**Budget-friendly alternative to NAT Gateway:**

```hcl
# Security group for NAT instance
resource "aws_security_group" "nat_instance" {
  name_prefix = "nat-instance-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# NAT instance (t3.micro is sufficient for low traffic)
resource "aws_instance" "nat" {
  ami                         = "ami-0123456789abcdef0"  # Amazon Linux NAT AMI
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.nat_instance.id]
  associate_public_ip_address = true
  source_dest_check           = false  # Critical for NAT

  tags = {
    Name = "lgtm-nat-instance"
  }
}

# Route to NAT instance
resource "aws_route" "nat_instance" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  instance_id            = aws_instance.nat.id
}
```

**Costs:**
- t3.micro: ~$0.0104/hour (~$7.50/month)
- Data transfer: Standard EC2 rates
- **Total**: ~$10-15/month

**Pros:**
- Much cheaper than NAT Gateway
- Sufficient for low-traffic workloads
- Can customize/tune

**Cons:**
- Manual management required
- Not as highly available
- Limited bandwidth
- Requires monitoring

---

## Load Balancer Patterns

### When to Use Load Balancers

**Use Application Load Balancer (ALB) when:**
- HTTP/HTTPS traffic
- Path-based or host-based routing
- WebSocket support
- Need WAF integration

**Use Network Load Balancer (NLB) when:**
- TCP/UDP/TLS traffic
- Extreme performance (millions of requests/sec)
- Static IP addresses required
- Low latency critical

**For LGTM Stack:**
- ALB for Grafana (HTTP traffic, SSL termination)
- NLB for OTLP endpoints (gRPC/Protobuf, performance)

---

## Application Load Balancer for Grafana

### Pattern: ALB with SSL Termination

```hcl
# Security group for ALB
resource "aws_security_group" "alb" {
  name_prefix = "lgtm-alb-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id

  # Allow HTTPS from anywhere
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  # Optional: HTTP redirect to HTTPS
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP redirect"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lgtm-alb-sg"
  }
}

# Application Load Balancer
resource "aws_lb" "grafana" {
  name               = "lgtm-grafana-alb"
  internal           = false  # Internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]

  # Deploy across multiple AZs for HA
  subnets = data.aws_subnets.public.ids

  enable_deletion_protection = true  # Prevent accidental deletion

  tags = {
    Name = "lgtm-grafana-alb"
  }
}

# Target group for Grafana
resource "aws_lb_target_group" "grafana" {
  name     = "lgtm-grafana-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.example_connect_target_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/api/health"
    matcher             = "200"
  }

  tags = {
    Name = "lgtm-grafana-tg"
  }
}

# Register EC2 instance as target
resource "aws_lb_target_group_attachment" "grafana" {
  target_group_arn = aws_lb_target_group.grafana.arn
  target_id        = aws_instance.lgtm_instance.id
  port             = 3000
}

# HTTPS listener (requires ACM certificate)
resource "aws_lb_listener" "grafana_https" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS-1-2-2017-01"
  certificate_arn   = aws_acm_certificate.grafana.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# HTTP listener (redirect to HTTPS)
resource "aws_lb_listener" "grafana_http" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ACM certificate for SSL
resource "aws_acm_certificate" "grafana" {
  domain_name       = "grafana.example.com"
  validation_method = "DNS"

  tags = {
    Name = "lgtm-grafana-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

**Benefits:**
- SSL termination at load balancer
- Multi-AZ high availability
- Health checking
- HTTP to HTTPS redirect
- Grafana instance can be in private subnet

**Costs:**
- ALB: ~$0.0225/hour (~$16/month)
- LCU: ~$0.008/hour per LCU (~$6/month)
- **Total**: ~$22/month

---

## Network Load Balancer for OTLP

### Pattern: NLB for gRPC Traffic

```hcl
# Network Load Balancer for OTLP
resource "aws_lb" "otlp" {
  name               = "lgtm-otlp-nlb"
  internal           = true  # VPC-internal only
  load_balancer_type = "network"

  # Deploy across multiple AZs
  subnets = data.aws_subnets.private.ids

  enable_deletion_protection = true

  tags = {
    Name = "lgtm-otlp-nlb"
  }
}

# Target group for OTLP gRPC
resource "aws_lb_target_group" "otlp_grpc" {
  name     = "lgtm-otlp-grpc-tg"
  port     = 4317
  protocol = "TCP"
  vpc_id   = data.aws_vpc.example_connect_target_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    protocol            = "TCP"
  }

  tags = {
    Name = "lgtm-otlp-grpc-tg"
  }
}

# Target group for OTLP HTTP
resource "aws_lb_target_group" "otlp_http" {
  name     = "lgtm-otlp-http-tg"
  port     = 4318
  protocol = "TCP"
  vpc_id   = data.aws_vpc.example_connect_target_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    protocol            = "TCP"
  }

  tags = {
    Name = "lgtm-otlp-http-tg"
  }
}

# Register targets
resource "aws_lb_target_group_attachment" "otlp_grpc" {
  target_group_arn = aws_lb_target_group.otlp_grpc.arn
  target_id        = aws_instance.lgtm_instance.id
  port             = 4317
}

resource "aws_lb_target_group_attachment" "otlp_http" {
  target_group_arn = aws_lb_target_group.otlp_http.arn
  target_id        = aws_instance.lgtm_instance.id
  port             = 4318
}

# gRPC listener
resource "aws_lb_listener" "otlp_grpc" {
  load_balancer_arn = aws_lb.otlp.arn
  port              = "4317"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.otlp_grpc.arn
  }
}

# HTTP listener
resource "aws_lb_listener" "otlp_http" {
  load_balancer_arn = aws_lb.otlp.arn
  port              = "4318"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.otlp_http.arn
  }
}
```

**Benefits:**
- High performance for gRPC
- Preserves client IP
- Static IP addresses
- Low latency
- Multi-AZ availability

**Costs:**
- NLB: ~$0.0225/hour (~$16/month)
- NLCU: ~$0.006/hour per NLCU (~$4/month)
- **Total**: ~$20/month

---

## Architecture Patterns

### Pattern 1: Simple Single-Instance (Current)

```text
Internet
    |
    v
[Internet Gateway]
    |
    v
[Public Subnet]
    |
    v
[EC2 Instance]
    |
  Grafana:3000 (public)
  OTLP:4317/4318 (VPC-only)
```

**Pros:**
- Simple
- Low cost
- Easy to understand

**Cons:**
- No high availability
- Single point of failure
- Grafana exposed directly

---

### Pattern 2: ALB with Private Instance

```text
Internet
    |
    v
[Internet Gateway]
    |
    v
[Public Subnet]
    |
    v
[Application Load Balancer]
    |
    v
[Private Subnet]
    |
    v
[EC2 Instance] --> [NAT Gateway] --> [Internet]
    |
  Grafana:3000 (via ALB)
  OTLP:4317/4318 (VPC-only)
```

**Pros:**
- SSL termination at ALB
- Instance in private subnet (more secure)
- Health checking
- Can scale to multiple instances

**Cons:**
- Higher cost (ALB + NAT)
- More complex

---

### Pattern 3: Multi-AZ High Availability

```text
Internet
    |
    v
[Internet Gateway]
    |
    +-------------------------------------------+
    |                                           |
    v                                           v
[Public Subnet AZ-1a]                    [Public Subnet AZ-1b]
    |                                           |
    v                                           v
[ALB Node 1a]                            [ALB Node 1b]
    |                                           |
    +-------------------+   +-------------------+
                        |   |
                        v   v
                  [Target Group]
                        |
        +---------------+---------------+
        |                               |
        v                               v
[Private Subnet AZ-1a]           [Private Subnet AZ-1b]
        |                               |
        v                               v
  [EC2 Instance 1a]              [EC2 Instance 1b]
        |                               |
        v                               v
  [NAT Gateway 1a]               [NAT Gateway 1b]
        |                               |
        +---------------+---------------+
                        |
                        v
                   [Internet]
```

**Pros:**
- High availability
- Automatic failover
- No single point of failure
- Production-ready

**Cons:**
- Highest cost
- Most complex
- Requires Auto Scaling Group

---

## VPC Peering and PrivateLink

### VPC Peering (Connect Multiple VPCs)

```hcl
# Create VPC peering connection
resource "aws_vpc_peering_connection" "lgtm_to_app" {
  vpc_id      = data.aws_vpc.lgtm_vpc.id
  peer_vpc_id = data.aws_vpc.application_vpc.id
  auto_accept = true

  tags = {
    Name = "lgtm-to-application-peering"
  }
}

# Add route to LGTM VPC route table
resource "aws_route" "lgtm_to_app" {
  route_table_id            = data.aws_route_table.lgtm_private.id
  destination_cidr_block    = data.aws_vpc.application_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.lgtm_to_app.id
}

# Add route to Application VPC route table
resource "aws_route" "app_to_lgtm" {
  route_table_id            = data.aws_route_table.app_private.id
  destination_cidr_block    = data.aws_vpc.lgtm_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.lgtm_to_app.id
}
```

**Use Case:**
- Connect LGTM stack VPC to application VPCs
- Allow applications to send telemetry data
- Avoid internet routing

---

### PrivateLink (Service Endpoints)

```hcl
# Create NLB for OTLP service
resource "aws_lb" "otlp_privatelink" {
  name               = "lgtm-otlp-privatelink-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = data.aws_subnets.private.ids
}

# Create VPC Endpoint Service
resource "aws_vpc_endpoint_service" "otlp" {
  acceptance_required        = false
  network_load_balancer_arns = [aws_lb.otlp_privatelink.arn]

  tags = {
    Name = "lgtm-otlp-endpoint-service"
  }
}

# In consumer VPC:
# Create VPC Endpoint to connect to service
resource "aws_vpc_endpoint" "otlp_consumer" {
  vpc_id              = data.aws_vpc.consumer_vpc.id
  service_name        = aws_vpc_endpoint_service.otlp.service_name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.consumer_private.ids
  security_group_ids  = [aws_security_group.otlp_endpoint.id]
  private_dns_enabled = true
}
```

**Benefits:**
- More secure than VPC peering
- No CIDR overlap concerns
- Scalable to many consumer VPCs
- Fine-grained access control

---

## DNS and Route 53 Integration

### Private Hosted Zone

```hcl
# Create private hosted zone for internal DNS
resource "aws_route53_zone" "private" {
  name = "lgtm.internal"

  vpc {
    vpc_id = data.aws_vpc.example_connect_target_vpc.id
  }

  tags = {
    Name = "lgtm-private-zone"
  }
}

# DNS record for Grafana (via ALB)
resource "aws_route53_record" "grafana" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "grafana.lgtm.internal"
  type    = "A"

  alias {
    name                   = aws_lb.grafana.dns_name
    zone_id                = aws_lb.grafana.zone_id
    evaluate_target_health = true
  }
}

# DNS record for OTLP collector
resource "aws_route53_record" "otlp" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "otlp.lgtm.internal"
  type    = "A"

  alias {
    name                   = aws_lb.otlp.dns_name
    zone_id                = aws_lb.otlp.zone_id
    evaluate_target_health = true
  }
}
```

**Benefits:**
- Stable DNS names (don't change with infra updates)
- Easy application configuration
- Supports health checks

---

## Security Groups for Load Balancers

### ALB Security Group Pattern

```hcl
# ALB security group (internet-facing)
resource "aws_security_group" "alb" {
  name_prefix = "lgtm-alb-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id

  # HTTPS from internet
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS from internet"
  }

  # HTTP (redirect only)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP redirect"
  }

  # Egress to Grafana instances
  egress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.grafana_instance.id]
    description     = "To Grafana instances"
  }
}

# Instance security group (accept from ALB only)
resource "aws_security_group" "grafana_instance" {
  name_prefix = "lgtm-grafana-instance-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id

  # Grafana from ALB only
  ingress {
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
    description     = "Grafana from ALB"
  }

  # Allow all egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

---

## Summary and Recommendations

### For Current LGTM Stack

**Immediate Improvements:**
1. **Add ALB for Grafana** - SSL termination, better security
2. **Move instance to private subnet** - Add NAT gateway for outbound
3. **Add NLB for OTLP** - Internal load balancing for telemetry
4. **Multi-AZ subnets** - Support high availability

**Architecture Evolution:**

**Phase 1: Current (Simple)**
- Single EC2 in public subnet
- Direct Grafana access
- VPC-scoped OTLP

**Phase 2: Secured (Recommended)**
- ALB for Grafana (SSL, public)
- NLB for OTLP (internal)
- EC2 in private subnet
- Single NAT gateway

**Phase 3: Highly Available (Production)**
- Multi-AZ ALB and NLB
- Auto Scaling Group (2+ instances)
- NAT gateway per AZ
- Route 53 private hosted zone

**Cost Comparison:**

| Architecture | Monthly Cost | Availability |
|--------------|--------------|--------------|
| Phase 1 (Current) | ~$20 | Single AZ |
| Phase 2 (Secured) | ~$75 | Single AZ |
| Phase 3 (HA) | ~$200 | Multi-AZ |

**Quick Win:**
- Add ALB for Grafana with SSL certificate
- Keep instance in public subnet initially
- Use security groups to restrict instance access
- Estimated additional cost: ~$25/month
