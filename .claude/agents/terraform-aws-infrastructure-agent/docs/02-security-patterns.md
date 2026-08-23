# Security Patterns

## Overview

This document covers AWS security best practices for Terraform-managed infrastructure, including security groups, IAM roles, Secrets Manager integration, and the principle of least privilege.

---

## Security Group Best Practices

### Principle of Least Privilege

**Core Principle:** Each security group should allow only the minimum network access required for its specific function.

### Current Configuration Analysis

```hcl
resource "aws_security_group" "lgtm_sg" {
  name_prefix = "lgtm-key-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id

  # Grafana - Public access
  ingress {
    from_port   = local.secrets.grafana_port
    to_port     = local.secrets.grafana_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # SECURITY CONSIDERATION
    description = "Allow Grafana HTTP (Public)"
  }

  # OTLP gRPC - VPC only
  ingress {
    from_port   = local.secrets.otlp_grpc_port
    to_port     = local.secrets.otlp_grpc_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.example_connect_target_vpc.cidr_block]
    description = "Allow OTLP gRPC from VPC"
  }

  # OTLP HTTP - VPC only
  ingress {
    from_port   = local.secrets.otlp_http_port
    to_port     = local.secrets.otlp_http_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.example_connect_target_vpc.cidr_block]
    description = "Allow OTLP HTTP from VPC"
  }

  # Tempo HTTP - VPC only
  ingress {
    from_port   = local.secrets.tempo_http_port
    to_port     = local.secrets.tempo_http_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.example_connect_target_vpc.cidr_block]
    description = "Allow Tempo HTTP from VPC"
  }

  # SSH - Restricted CIDR
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.secrets.ssh_ingress_cidr]
    description = "Allow SSH access"
  }

  # Egress - Allow all (SECURITY CONSIDERATION)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

**Security Analysis:**

**GOOD Practices:**
1. ✅ OTLP endpoints restricted to VPC CIDR only
2. ✅ SSH restricted to specific CIDR block
3. ✅ Descriptive rule descriptions
4. ✅ Uses `name_prefix` for unique naming
5. ✅ Tempo HTTP restricted to VPC

**Improvement Opportunities:**
1. ⚠️ Grafana exposed to entire internet (0.0.0.0/0)
2. ⚠️ Egress allows all traffic (can be more restrictive)
3. ⚠️ No separate security groups by function

---

## Security Group Design Patterns

### Pattern 1: Separate Security Groups per Function

**Recommended Approach:**

```hcl
# 1. Grafana Security Group (Public-facing)
resource "aws_security_group" "grafana_sg" {
  name_prefix = "lgtm-grafana-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id
  description = "Security group for Grafana dashboard"

  tags = {
    Name = "lgtm-grafana-sg"
  }
}

resource "aws_security_group_rule" "grafana_http" {
  type              = "ingress"
  security_group_id = aws_security_group.grafana_sg.id
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]  # Or restrict to CloudFront IPs
  description       = "Grafana HTTP access"
}

# 2. OTLP Collector Security Group (VPC-internal)
resource "aws_security_group" "otlp_collector_sg" {
  name_prefix = "lgtm-otlp-collector-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id
  description = "Security group for OTLP data collection"

  tags = {
    Name = "lgtm-otlp-collector-sg"
  }
}

resource "aws_security_group_rule" "otlp_grpc" {
  type              = "ingress"
  security_group_id = aws_security_group.otlp_collector_sg.id
  from_port         = 4317
  to_port           = 4317
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  description       = "OTLP gRPC from VPC"
}

resource "aws_security_group_rule" "otlp_http" {
  type              = "ingress"
  security_group_id = aws_security_group.otlp_collector_sg.id
  from_port         = 4318
  to_port           = 4318
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  description       = "OTLP HTTP from VPC"
}

# 3. LGTM Backends Security Group (Internal services)
resource "aws_security_group" "lgtm_backends_sg" {
  name_prefix = "lgtm-backends-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id
  description = "Security group for Loki, Tempo, Mimir"

  tags = {
    Name = "lgtm-backends-sg"
  }
}

resource "aws_security_group_rule" "loki_http" {
  type              = "ingress"
  security_group_id = aws_security_group.lgtm_backends_sg.id
  from_port         = 3100
  to_port           = 3100
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  description       = "Loki HTTP API"
}

resource "aws_security_group_rule" "tempo_http" {
  type              = "ingress"
  security_group_id = aws_security_group.lgtm_backends_sg.id
  from_port         = 3200
  to_port           = 3200
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  description       = "Tempo HTTP API"
}

resource "aws_security_group_rule" "mimir_http" {
  type              = "ingress"
  security_group_id = aws_security_group.lgtm_backends_sg.id
  from_port         = 9009
  to_port           = 9009
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  description       = "Mimir HTTP API"
}

# 4. SSH Security Group (Management)
resource "aws_security_group" "ssh_sg" {
  name_prefix = "lgtm-ssh-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id
  description = "SSH access for management"

  tags = {
    Name = "lgtm-ssh-sg"
  }
}

resource "aws_security_group_rule" "ssh_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.ssh_sg.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [local.secrets.ssh_ingress_cidr]
  description       = "SSH from authorized networks"
}

# Apply all security groups to instance
resource "aws_instance" "lgtm_instance" {
  # ... other config
  vpc_security_group_ids = [
    aws_security_group.grafana_sg.id,
    aws_security_group.otlp_collector_sg.id,
    aws_security_group.lgtm_backends_sg.id,
    aws_security_group.ssh_sg.id,
  ]
}
```

**Benefits:**
- Each security group has a single responsibility
- Easier to audit and modify
- Can be independently attached/detached
- Better security posture isolation

---

### Pattern 2: Source Security Group References

**Instead of CIDR blocks, reference security groups:**

```hcl
# Application tier security group
resource "aws_security_group" "application_sg" {
  name_prefix = "app-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id
}

# OTLP collector accepts traffic from application security group
resource "aws_security_group_rule" "otlp_from_app" {
  type                     = "ingress"
  security_group_id        = aws_security_group.otlp_collector_sg.id
  from_port                = 4318
  to_port                  = 4318
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.application_sg.id
  description              = "OTLP HTTP from application tier"
}

# Grafana can query Loki/Tempo/Mimir
resource "aws_security_group_rule" "backends_from_grafana" {
  type                     = "ingress"
  security_group_id        = aws_security_group.lgtm_backends_sg.id
  from_port                = 3100
  to_port                  = 3200
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.grafana_sg.id
  description              = "Allow Grafana to query backends"
}
```

**Benefits:**
- Automatic IP management (no need to update CIDRs)
- Works across subnet changes
- More secure (only specific resources can connect)

---

### Pattern 3: Restrictive Egress Rules

**Default deny, explicitly allow:**

```hcl
# Egress for HTTPS (package updates, AWS API calls)
resource "aws_security_group_rule" "egress_https" {
  type              = "egress"
  security_group_id = aws_security_group.lgtm_sg.id
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTPS for updates and AWS API"
}

# Egress for HTTP (if needed for non-TLS repos)
resource "aws_security_group_rule" "egress_http" {
  type              = "egress"
  security_group_id = aws_security_group.lgtm_sg.id
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTP for package repositories"
}

# Egress for DNS
resource "aws_security_group_rule" "egress_dns" {
  type              = "egress"
  security_group_id = aws_security_group.lgtm_sg.id
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "DNS resolution"
}

# Egress to internal VPC (for service communication)
resource "aws_security_group_rule" "egress_vpc" {
  type              = "egress"
  security_group_id = aws_security_group.lgtm_sg.id
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.example_connect_target_vpc.cidr_block]
  description       = "All TCP within VPC"
}
```

---

### Pattern 4: Default Security Group Lockdown

**Best Practice: Restrict the default security group**

```hcl
# Retrieve default security group
data "aws_security_group" "default" {
  vpc_id = data.aws_vpc.example_connect_target_vpc.id
  name   = "default"
}

# Remove all default rules and lock it down
resource "aws_security_group_rule" "default_deny_ingress" {
  type              = "ingress"
  security_group_id = data.aws_security_group.default.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true  # Only allow traffic from same security group
  description       = "Deny all ingress by default"
}

# Tag to prevent usage
resource "aws_ec2_tag" "default_sg_warning" {
  resource_id = data.aws_security_group.default.id
  key         = "Usage"
  value       = "DO NOT USE - Locked down for security"
}
```

---

## IAM Roles and Instance Profiles

### Current Gap

The current configuration does not include an IAM instance profile, which means:
- Cannot use AWS APIs without hardcoded credentials
- Cannot retrieve Secrets Manager secrets securely
- Cannot send CloudWatch metrics/logs without embedded keys

### Recommended IAM Pattern

**1. Base IAM Role for EC2:**

```hcl
resource "aws_iam_role" "lgtm_instance_role" {
  name               = "lgtm-instance-role"
  description        = "IAM role for LGTM stack EC2 instances"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "lgtm-instance-role"
  }
}

resource "aws_iam_instance_profile" "lgtm_profile" {
  name = "lgtm-instance-profile"
  role = aws_iam_role.lgtm_instance_role.name
}
```

**2. Secrets Manager Access (Least Privilege):**

```hcl
# Custom policy for read-only access to specific secret
resource "aws_iam_policy" "lgtm_secrets_read" {
  name        = "lgtm-secrets-read-policy"
  description = "Read access to LGTM stack secrets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = data.aws_secretsmanager_secret.lgtm_secrets.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lgtm_secrets_attach" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = aws_iam_policy.lgtm_secrets_read.policy_arn
}
```

**3. CloudWatch Monitoring Access:**

```hcl
# Attach AWS managed policy for CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Optional: Custom CloudWatch policy for specific metrics
resource "aws_iam_policy" "lgtm_cloudwatch_custom" {
  name        = "lgtm-cloudwatch-custom-policy"
  description = "Custom CloudWatch metrics for LGTM stack"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "*"
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = "LGTM/Stack"
        }
      }
    }]
  })
}
```

**4. SSM Session Manager Access (SSH Alternative):**

```hcl
# Enable SSM Session Manager for secure shell access without SSH
resource "aws_iam_role_policy_attachment" "ssm_managed_instance" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Benefits:
# - No need for SSH key management
# - Session logging and audit trails
# - Access through AWS console or CLI
# - No need for public IP or bastion host
```

**5. S3 Access for Backups (Optional):**

```hcl
resource "aws_iam_policy" "lgtm_s3_backup" {
  name        = "lgtm-s3-backup-policy"
  description = "S3 access for LGTM data backups"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ]
      Resource = [
        "arn:aws:s3:::lgtm-backups-bucket",
        "arn:aws:s3:::lgtm-backups-bucket/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lgtm_s3_attach" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = aws_iam_policy.lgtm_s3_backup.policy_arn
}
```

---

## Secrets Manager Integration

### Current Pattern Analysis

```hcl
# Read secret from Secrets Manager
data "aws_secretsmanager_secret" "lgtm_secrets" {
  name = "/example/dev/lgtm-stack"
}

data "aws_secretsmanager_secret_version" "lgtm_secrets_version" {
  secret_id = data.aws_secretsmanager_secret.lgtm_secrets.id
}

locals {
  secrets = jsondecode(data.aws_secretsmanager_secret_version.lgtm_secrets_version.secret_string)
}
```

**This is GOOD practice:** Terraform reads secrets at plan/apply time, but secrets are not hardcoded in configuration.

### Best Practices

**1. Secret Naming Convention:**

```text
Format: /{organization}/{environment}/{service-name}

Examples:
/example/dev/lgtm-stack
/example/prod/lgtm-stack
/example/uat/lgtm-stack
```

**2. Secret Structure (JSON):**

```json
{
  "vpc_id": "vpc-xxxxxxxxx",
  "instance_type": "t3.large",
  "ssh_public_key_pair_name": "lgtm-key",
  "ssh_ingress_cidr": "203.0.113.0/24",
  "grafana_port": "3000",
  "otlp_grpc_port": "4317",
  "otlp_http_port": "4318",
  "tempo_http_port": "3200",
  "git_access_key": "base64-encoded-ssh-key",
  "git_repo_url": "git@github.com:youruser/lgtm-stack-experiment.git"
}
```

**3. Managing Secrets with Terraform:**

```hcl
# Create secret (one-time, then manage values manually)
resource "aws_secretsmanager_secret" "lgtm_secrets" {
  name                    = "/example/dev/lgtm-stack"
  description             = "Configuration secrets for LGTM stack"
  recovery_window_in_days = 7  # Grace period before permanent deletion

  tags = {
    Environment = "dev"
    Service     = "lgtm-stack"
  }
}

# Optionally set initial value (NOT RECOMMENDED for sensitive data)
# Better to set manually via AWS Console or CLI
resource "aws_secretsmanager_secret_version" "lgtm_secrets_initial" {
  secret_id = aws_secretsmanager_secret.lgtm_secrets.id
  secret_string = jsonencode({
    vpc_id        = "vpc-xxxxxxxxx"
    instance_type = "t3.large"
    # ... non-sensitive defaults
  })

  lifecycle {
    ignore_changes = [secret_string]  # Prevent Terraform from overwriting manual changes
  }
}
```

**4. Secret Rotation (Advanced):**

```hcl
# Enable automatic rotation for secrets (e.g., database passwords)
resource "aws_secretsmanager_secret_rotation" "lgtm_db_rotation" {
  secret_id           = aws_secretsmanager_secret.lgtm_db.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

**5. Retrieving Secrets in User Data:**

```bash
#!/bin/bash
# Use IAM instance profile to retrieve secrets (no credentials needed)

# Install jq for JSON parsing
yum install -y jq

# Retrieve secret from Secrets Manager
SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "/example/dev/lgtm-stack" \
    --region us-east-1 \
    --query SecretString \
    --output text)

# Parse individual values
REPO_URL=$(echo "$SECRET_JSON" | jq -r '.git_repo_url')
SSH_KEY=$(echo "$SECRET_JSON" | jq -r '.git_access_key' | base64 -d)

# Use values securely
echo "$SSH_KEY" > /home/ec2-user/.ssh/id_ed25519
chmod 600 /home/ec2-user/.ssh/id_ed25519
```

---

## IAM Policy Best Practices

### 1. Least Privilege Principle

**Always start with deny-all, add only required permissions:**

```hcl
# BAD - Overly permissive
policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect   = "Allow"
    Action   = "s3:*"      # ALL S3 actions
    Resource = "*"         # ALL resources
  }]
})

# GOOD - Specific permissions
policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect = "Allow"
    Action = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    Resource = "arn:aws:s3:::lgtm-backups-bucket/*"
  }, {
    Effect = "Allow"
    Action = "s3:ListBucket"
    Resource = "arn:aws:s3:::lgtm-backups-bucket"
  }]
})
```

### 2. Use Conditions to Further Restrict

```hcl
policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect = "Allow"
    Action = "s3:PutObject"
    Resource = "arn:aws:s3:::lgtm-backups-bucket/*"
    Condition = {
      StringEquals = {
        "s3:x-amz-server-side-encryption" = "AES256"  # Require encryption
      }
      IpAddress = {
        "aws:SourceIp" = "10.0.0.0/8"  # Only from private IPs
      }
    }
  }]
})
```

### 3. Use AWS Managed Policies Where Appropriate

```hcl
# Use AWS managed policies for standard use cases
resource "aws_iam_role_policy_attachment" "managed_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = each.value
}
```

### 4. Tag-Based Access Control

```hcl
# Allow actions only on resources with specific tags
policy = jsonencode({
  Version = "2012-10-17"
  Statement = [{
    Effect = "Allow"
    Action = [
      "ec2:StartInstances",
      "ec2:StopInstances"
    ]
    Resource = "*"
    Condition = {
      StringEquals = {
        "ec2:ResourceTag/Environment" = "dev"
        "ec2:ResourceTag/ManagedBy"   = "terraform"
      }
    }
  }]
})
```

### 5. Use IAM Access Analyzer

```hcl
# Enable IAM Access Analyzer to detect overly permissive policies
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "account-analyzer"
  type          = "ACCOUNT"

  tags = {
    Name = "Account-wide IAM Analyzer"
  }
}
```

---

## Encryption Best Practices

### 1. EBS Encryption by Default

```hcl
# Enable EBS encryption by default at account level
resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}

# Use customer-managed KMS key (optional, for audit logs)
resource "aws_kms_key" "lgtm_ebs" {
  description             = "KMS key for LGTM EBS volumes"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "lgtm-ebs-key"
  }
}

resource "aws_kms_alias" "lgtm_ebs" {
  name          = "alias/lgtm-ebs"
  target_key_id = aws_kms_key.lgtm_ebs.id
}

resource "aws_ebs_default_kms_key" "lgtm" {
  key_arn = aws_kms_key.lgtm_ebs.arn
}
```

### 2. Secrets Manager Encryption

```hcl
# Use custom KMS key for Secrets Manager
resource "aws_kms_key" "secrets" {
  description             = "KMS key for Secrets Manager"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow Secrets Manager to use the key"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_secretsmanager_secret" "lgtm_secrets_encrypted" {
  name       = "/example/dev/lgtm-stack"
  kms_key_id = aws_kms_key.secrets.id
}
```

### 3. Instance Metadata Encryption

```hcl
resource "aws_instance" "lgtm_instance" {
  # ... other config

  # Enable encryption of instance metadata
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2 required
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
}
```

---

## Network Security Patterns

### 1. Private Subnet Pattern

**For production, place instances in private subnets:**

```hcl
# Private subnet with NAT gateway for internet access
resource "aws_instance" "lgtm_private" {
  ami                         = data.aws_ami.latest_linux_2.id
  instance_type               = local.secrets.instance_type
  subnet_id                   = data.aws_subnet.private_subnet.id  # Private subnet
  vpc_security_group_ids      = [aws_security_group.lgtm_sg.id]
  associate_public_ip_address = false  # No public IP

  # ... other config
}

# Access via Systems Manager Session Manager (no SSH needed)
# Or via bastion host in public subnet
```

### 2. VPC Endpoints for AWS Services

**Avoid internet traffic for AWS API calls:**

```hcl
# VPC endpoint for Secrets Manager
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.example_connect_target_vpc.id
  service_name        = "com.amazonaws.us-east-1.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.private_subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

# VPC endpoint for CloudWatch
resource "aws_vpc_endpoint" "cloudwatch" {
  vpc_id              = data.aws_vpc.example_connect_target_vpc.id
  service_name        = "com.amazonaws.us-east-1.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [data.aws_subnet.private_subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

# VPC endpoint for S3 (Gateway type - free)
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = data.aws_vpc.example_connect_target_vpc.id
  service_name = "com.amazonaws.us-east-1.s3"
}
```

---

## Security Monitoring and Auditing

### 1. CloudTrail for API Auditing

```hcl
# Enable CloudTrail for API call logging
resource "aws_cloudtrail" "lgtm_trail" {
  name                          = "lgtm-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::lgtm-backups-bucket/*"]
    }
  }
}

resource "aws_s3_bucket" "cloudtrail_logs" {
  bucket = "lgtm-cloudtrail-logs"

  tags = {
    Name = "lgtm-cloudtrail-logs"
  }
}
```

### 2. GuardDuty for Threat Detection

```hcl
# Enable GuardDuty for threat detection
resource "aws_guardduty_detector" "lgtm" {
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = false
      }
    }
  }
}
```

### 3. Security Hub for Compliance

```hcl
# Enable Security Hub for compliance checks
resource "aws_securityhub_account" "lgtm" {}

# Enable CIS AWS Foundations Benchmark
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:us-east-1::standards/cis-aws-foundations-benchmark/v/1.4.0"

  depends_on = [aws_securityhub_account.lgtm]
}
```

---

## Summary of Security Improvements

### For Current LGTM Stack Configuration

**High Priority:**
1. Add IAM instance profile for AWS API access
2. Restrict Grafana access (consider CloudFront or VPN)
3. Enable IMDSv2 requirement
4. Add restrictive egress rules
5. Enable EBS encryption by default

**Medium Priority:**
6. Separate security groups by function
7. Enable CloudWatch detailed monitoring
8. Add VPC endpoints for AWS services
9. Implement Systems Manager Session Manager

**Low Priority:**
10. Enable GuardDuty
11. Enable Security Hub
12. Implement CloudTrail logging
13. Use custom KMS keys for encryption

**Quick Wins:**
```hcl
# Add these to existing main.tf immediately:

# 1. IAM instance profile
resource "aws_iam_role" "lgtm_instance_role" {
  # ... (see above)
}

resource "aws_iam_instance_profile" "lgtm_profile" {
  # ... (see above)
}

# 2. Update instance with security improvements
resource "aws_instance" "lgtm_instance" {
  # ... existing config

  iam_instance_profile = aws_iam_instance_profile.lgtm_profile.name

  metadata_options {
    http_tokens = "required"  # IMDSv2
  }

  root_block_device {
    encrypted = true
  }
}

# 3. Enable EBS encryption account-wide
resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}
```
