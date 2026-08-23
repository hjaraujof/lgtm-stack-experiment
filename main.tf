terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state. Keep this enabled: the state file records the full resource
  # graph of a live deployment, so a local terraform.tfstate on a laptop is both
  # a loss risk and a disclosure risk. Substitute your own bucket, then
  # `terraform init`. Create the bucket out of band -- a backend block cannot
  # depend on a resource in the same configuration.
  backend "s3" {
    bucket       = "example-terraform-state"
    key          = "lgtm-stack/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

# METADATA ONLY. This resolves the secret's ARN and name. It does NOT read the
# secret value, so `terraform plan` never calls secretsmanager:GetSecretValue
# and no password or key is written into the state file, into a CI plan log, or
# into the rendered EC2 user_data. The instance fetches the values itself at
# boot through its IAM role -- see the boot-fetch block in user_data.tpl.
#
# Do not add an aws_secretsmanager_secret_version data source here.
data "aws_secretsmanager_secret" "lgtm_secrets" {
  name = var.secret_name
}

data "aws_vpc" "target_vpc" {
  id = var.vpc_id
}

# =============================================================================
# LGTM Subnet - Dedicated public subnet for the observability stack
# =============================================================================
# A dedicated subnet, rather than an existing one, because it:
# - Keeps LGTM infrastructure self-contained
# - Can be destroyed without affecting other deployments
# - Is associated with the public route table for internet access
#
# Choose var.availability_zone to match var.instance_type. Not every AZ offers
# every instance family, and the failure surfaces only at apply time.

resource "aws_subnet" "lgtm_public" {
  vpc_id                  = data.aws_vpc.target_vpc.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name      = "lgtm-stack"
    Purpose   = "LGTM observability stack"
    ManagedBy = "terraform"
  }
}

# Look up the public route table (has route to Internet Gateway)
data "aws_route_table" "public" {
  vpc_id = data.aws_vpc.target_vpc.id

  filter {
    name   = "route.gateway-id"
    values = [var.internet_gateway_id]
  }
}

# Associate the LGTM subnet with the public route table
resource "aws_route_table_association" "lgtm_public" {
  subnet_id      = aws_subnet.lgtm_public.id
  route_table_id = data.aws_route_table.public.id
}

data "aws_key_pair" "lgtm_key" {
  key_name = var.ssh_public_key_pair_name
}

resource "aws_security_group" "lgtm_sg" {
  name_prefix = "lgtm-key-"
  vpc_id      = data.aws_vpc.target_vpc.id

  # Allow HTTPS access from anywhere (SSL via NGINX)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS (Public)"
  }

  # Allow HTTP for Let's Encrypt ACME challenge and redirect
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP for ACME challenge (Public)"
  }

  # Allow Grafana direct access from VPC only (fallback)
  ingress {
    from_port   = var.grafana_port
    to_port     = var.grafana_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.target_vpc.cidr_block]
    description = "Allow Grafana HTTP from VPC (fallback)"
  }

  # Allow OTLP gRPC from within the VPC
  ingress {
    from_port   = var.otlp_grpc_port
    to_port     = var.otlp_grpc_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.target_vpc.cidr_block]
    description = "Allow OTLP gRPC from VPC"
  }

  # Allow OTLP HTTP from within the VPC
  ingress {
    from_port   = var.otlp_http_port
    to_port     = var.otlp_http_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.target_vpc.cidr_block]
    description = "Allow OTLP HTTP from VPC"
  }

  # Optional: Allow Tempo HTTP from within the VPC
  ingress {
    from_port   = var.tempo_http_port
    to_port     = var.tempo_http_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.target_vpc.cidr_block]
    description = "Allow Tempo HTTP from VPC"
  }

  # SSH (port 22) intentionally CLOSED. Access is via SSM Session Manager (aws ssm start-session),
  # which needs no inbound port. Git is outbound. To restore break-glass SSH temporarily (e.g. if a
  # full disk breaks the SSM agent), re-add this rule scoped to EC2 Instance Connect's IP range or a
  # trusted CIDR — do NOT reintroduce 0.0.0.0/0 (was the prior insecure default):
  # ingress {
  #   from_port   = 22
  #   to_port     = 22
  #   protocol    = "tcp"
  #   cidr_blocks = [var.ssh_ingress_cidr]  # set to a trusted CIDR, never 0.0.0.0/0
  #   description = "Allow SSH access (break-glass only)"
  # }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lgtm-security-group"
  }
}

# =============================================================================
# IAM Role for EC2 Instance (CloudWatch Agent)
# =============================================================================

resource "aws_iam_role" "lgtm_instance_role" {
  name = "lgtm-ec2-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name      = "lgtm-ec2-instance-role"
    ManagedBy = "terraform"
  }
}

# Attach CloudWatch Agent policy
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Attach SSM policy for parameter store access (optional but useful)
resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The instance boot-fetches the true secrets (the 3 Grafana passwords and the
# git deploy key) through this role -- see the boot-fetch block in user_data.tpl.
# The grant is scoped to the one secret by ARN, taken from the metadata data
# source, so no value is read at plan time.
#
# WITHOUT this policy a rebuilt instance cannot fetch its secrets, and
# user_data.tpl aborts with a FATAL line in /tmp/git-clone-setup.log rather than
# booting a stack with blank passwords.
resource "aws_iam_role_policy" "lgtm_secrets_read" {
  name = "lgtm-secrets-read"
  role = aws_iam_role.lgtm_instance_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadLgtmSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = data.aws_secretsmanager_secret.lgtm_secrets.arn
      }
    ]
  })
}

# Instance profile to attach the role to EC2
resource "aws_iam_instance_profile" "lgtm_instance_profile" {
  name = "lgtm-ec2-instance-profile"
  role = aws_iam_role.lgtm_instance_role.name
}

# =============================================================================
# AMI Lookup
# =============================================================================

data "aws_ami" "latest_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_instance" "lgtm_instance" {
  ami                         = data.aws_ami.latest_linux_2.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.lgtm_public.id
  vpc_security_group_ids      = [aws_security_group.lgtm_sg.id]
  key_name                    = data.aws_key_pair.lgtm_key.key_name
  iam_instance_profile        = aws_iam_instance_profile.lgtm_instance_profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 150
    volume_type = "gp3"
  }

  # Only non-secret values are templated here. The rendered user_data is
  # readable by anything on the box through the instance metadata service, and
  # it is stored verbatim in the state file, so a secret placed here is a secret
  # published twice. The instance boot-fetches the real secrets by name.
  user_data = templatefile("${path.module}/user_data.tpl", {
    domain_name      = var.domain_name
    certbot_email    = var.certbot_email
    secret_name      = data.aws_secretsmanager_secret.lgtm_secrets.name
    bootstrap_bucket = aws_s3_bucket.lgtm_bootstrap.bucket
  })

  tags = {
    Name = "lgtm-ec2-instance"
  }

  lifecycle {
    # Pin the AMI: data.aws_ami.latest_linux_2 uses most_recent=true, which resolves a
    # NEWER AL2023 image over time. Without this, every `tofu apply` would force-REPLACE
    # the instance (destroying the root EBS + all telemetry). Ignoring AMI drift keeps the
    # running instance in place so apply is non-destructive. A deliberate AMI/arch change
    # (e.g. the future Graviton move) will temporarily remove this and pin an exact AMI.
    ignore_changes = [ami]
  }
}

# =============================================================================
# DNS Configuration - Public (Grafana UI)
# =============================================================================

# Look up the existing public hosted zone that contains var.domain_name
data "aws_route53_zone" "public" {
  name         = var.public_zone_name
  private_zone = false
}

# Create an A record pointing to the LGTM EC2 instance (public)
resource "aws_route53_record" "lgtm_grafana" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = var.domain_name
  type    = "A"
  ttl     = 300

  records = [aws_instance.lgtm_instance.public_ip]
}

# =============================================================================
# DNS Configuration - Private (OTLP Endpoint for VPC-internal services)
# =============================================================================

# Private hosted zone for internal service discovery
resource "aws_route53_zone" "internal" {
  name = var.internal_zone_name

  vpc {
    vpc_id = data.aws_vpc.target_vpc.id
  }

  tags = {
    Name        = "internal-example"
    Description = "Private hosted zone for internal service discovery"
  }
}

# OTel Collector internal DNS record (points to EC2 private IP)
resource "aws_route53_record" "otel_collector" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "otel-collector"
  type    = "A"
  ttl     = 300

  records = [aws_instance.lgtm_instance.private_ip]
}

# =============================================================================
# Outputs
# =============================================================================

output "lgtm_dns_name" {
  description = "Public DNS name for Grafana UI"
  value       = aws_route53_record.lgtm_grafana.fqdn
}

output "otel_collector_internal_dns" {
  description = "Internal DNS name for OTel Collector (use within VPC)"
  value       = "${aws_route53_record.otel_collector.name}.${aws_route53_zone.internal.name}"
}

output "otel_collector_endpoint_http" {
  description = "OTLP HTTP endpoint for instrumentation"
  value       = "http://${aws_route53_record.otel_collector.name}.${aws_route53_zone.internal.name}:4318"
}

output "otel_collector_endpoint_grpc" {
  description = "OTLP gRPC endpoint for instrumentation"
  value       = "http://${aws_route53_record.otel_collector.name}.${aws_route53_zone.internal.name}:4317"
}