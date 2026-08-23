# Terraform Best Practices

## Overview

This document covers Terraform best practices including state management, module design, variable patterns, code organization, testing, and CI/CD integration.

---

## State Management

### Remote State with S3 Backend

**Why Remote State?**
- **Team Collaboration**: Multiple developers can work on same infrastructure
- **State Locking**: Prevents concurrent modifications (race conditions)
- **Versioning**: State file history and rollback capability
- **Security**: Centralized access control
- **Backup**: Automatic backups via S3 versioning

### S3 Backend Configuration

**IMPORTANT: Terraform now supports native S3 locking (DynamoDB is deprecated)**

#### New Recommended Pattern (S3 Native Locking)

```hcl
terraform {
  required_version = ">= 1.9.0"  # S3 native locking available in 1.9+

  backend "s3" {
    bucket       = "example-terraform-state"
    key          = "lgtm-stack/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true  # NEW: S3 native locking (no DynamoDB needed!)

    # Optional: Additional security
    kms_key_id = "arn:aws:kms:us-east-1:ACCOUNT_ID:key/KEY_ID"

    # Optional: Workspace support
    workspace_key_prefix = "env"  # Creates env/dev/, env/prod/, etc.
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

#### Legacy Pattern (DynamoDB Locking - Still Supported)

```hcl
terraform {
  backend "s3" {
    bucket         = "example-terraform-state"
    key            = "lgtm-stack/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"  # Legacy locking

    # Can use both during migration
    use_lockfile   = true
  }
}
```

**DynamoDB Table Requirements** (if using legacy locking):
- Table name matches `dynamodb_table` value
- Partition key: `LockID` (type: String)
- Provisioned or on-demand capacity

```bash
# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### S3 State Bucket Setup

```hcl
# Create S3 bucket for Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "example-terraform-state"

  tags = {
    Name        = "Terraform State"
    Environment = "shared"
    ManagedBy   = "terraform"
  }
}

# Enable versioning for state file history
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable access logging
resource "aws_s3_bucket_logging" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "terraform-state-access-logs/"
}

# Lifecycle policy for old versions
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "delete-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90  # Keep 90 days of history
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# KMS key for state encryption
resource "aws_kms_key" "terraform_state" {
  description             = "KMS key for Terraform state encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name = "terraform-state-encryption"
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/terraform-state"
  target_key_id = aws_kms_key.terraform_state.id
}
```

### State File Organization Patterns

**Pattern 1: Environment-Based Keys**

```text
example-terraform-state/
├── lgtm-stack/
│   ├── dev/terraform.tfstate
│   ├── staging/terraform.tfstate
│   └── prod/terraform.tfstate
├── api-gateway/
│   ├── dev/terraform.tfstate
│   └── prod/terraform.tfstate
```

**Pattern 2: Service-Based Keys**

```text
example-terraform-state/
├── networking/
│   └── vpc/terraform.tfstate
├── observability/
│   ├── lgtm-stack/terraform.tfstate
│   └── cloudwatch/terraform.tfstate
├── applications/
│   ├── api/terraform.tfstate
│   └── web/terraform.tfstate
```

**Pattern 3: Workspace-Based**

```hcl
terraform {
  backend "s3" {
    bucket               = "example-terraform-state"
    key                  = "lgtm-stack/terraform.tfstate"
    workspace_key_prefix = "env"  # Creates env/dev/, env/staging/, env/prod/
    region               = "us-east-1"
  }
}
```

### State Locking Benefits

**Without Locking:**
```text
Developer A: terraform apply (starts)
Developer B: terraform apply (starts) ← CONFLICT!
Developer A: Modifies security group
Developer B: Modifies security group ← OVERWRITES A's changes!
Result: Inconsistent state, lost changes
```

**With Locking (S3 Native or DynamoDB):**
```text
Developer A: terraform apply (acquires lock)
Developer B: terraform apply (waits for lock)
Developer A: Completes, releases lock
Developer B: Acquires lock, proceeds safely
Result: Sequential, safe operations
```

---

## Code Organization and Structure

### Current Structure Analysis

```text
lgtm-stack-experiment/
├── main.tf              # All resources in one file
├── user_data.tpl        # User data template
└── .gitignore
```

**Issues:**
- Everything in one file (difficult to navigate)
- No separation of concerns
- No reusable modules
- Variables hardcoded in locals from Secrets Manager

### Recommended Structure (Standard Module Pattern)

```text
lgtm-stack-experiment/
├── main.tf                   # Root module - orchestrates resources
├── variables.tf              # Input variables
├── outputs.tf                # Output values
├── versions.tf               # Terraform and provider versions
├── backend.tf                # Backend configuration (can be in main.tf)
├── data.tf                   # Data sources
├── locals.tf                 # Local values
├── ec2.tf                    # EC2 instance resources
├── security_groups.tf        # Security group resources
├── iam.tf                    # IAM roles and policies
├── load_balancers.tf         # ALB/NLB resources
├── user_data.tpl             # User data template
├── terraform.tfvars          # Variable values (gitignored)
├── terraform.tfvars.example  # Example variables (committed)
└── README.md                 # Documentation
```

### Alternative: Modular Structure (Advanced)

```text
lgtm-stack-experiment/
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   ├── staging/
│   │   └── ...
│   └── prod/
│       └── ...
├── modules/
│   ├── lgtm-instance/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── user_data.tpl
│   ├── lgtm-networking/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── lgtm-security/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── README.md
```

---

## Refactored Configuration Example

### versions.tf

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

### backend.tf

```hcl
terraform {
  backend "s3" {
    bucket       = "example-terraform-state"
    key          = "lgtm-stack/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true

    # Optional: Use workspaces for environments
    # workspace_key_prefix = "env"
  }
}
```

### variables.tf

```hcl
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_id" {
  description = "VPC ID for LGTM stack"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for LGTM instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "ssh_key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "ssh_ingress_cidr" {
  description = "CIDR block allowed to SSH"
  type        = string
  default     = "10.0.0.0/8"  # Default to private IPs only
}

variable "grafana_port" {
  description = "Grafana HTTP port"
  type        = number
  default     = 3000
}

variable "otlp_grpc_port" {
  description = "OTLP gRPC port"
  type        = number
  default     = 4317
}

variable "otlp_http_port" {
  description = "OTLP HTTP port"
  type        = number
  default     = 4318
}

variable "tempo_http_port" {
  description = "Tempo HTTP port"
  type        = number
  default     = 3200
}

variable "git_repo_url" {
  description = "Git repository URL"
  type        = string
  sensitive   = true
}

variable "git_access_key" {
  description = "Base64-encoded SSH deploy key for the git host"
  type        = string
  sensitive   = true
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project   = "lgtm-stack"
    ManagedBy = "terraform"
  }
}
```

### terraform.tfvars (gitignored)

```hcl
environment        = "dev"
vpc_id            = "vpc-0123456789abcdef"
subnet_id         = "subnet-0123456789abcdef"
instance_type     = "t3.large"
ssh_key_name      = "lgtm-key"
ssh_ingress_cidr  = "203.0.113.0/24"

# Sensitive values loaded from environment or secrets
# git_repo_url    = "git@github.com:youruser/lgtm-stack-experiment.git"
# git_access_key  = "base64-encoded-key"

common_tags = {
  Project     = "lgtm-stack"
  Environment = "dev"
  Owner       = "devops-team"
  ManagedBy   = "terraform"
}
```

### terraform.tfvars.example (committed to git)

```hcl
# Copy this file to terraform.tfvars and fill in values
# DO NOT commit terraform.tfvars to git

environment       = "dev"
vpc_id           = "vpc-xxxxxxxxx"
subnet_id        = "subnet-xxxxxxxxx"
instance_type    = "t3.large"
ssh_key_name     = "your-key-name"
ssh_ingress_cidr = "your.office.ip/32"

# Get these from AWS Secrets Manager or environment variables
# git_repo_url   = "git@github.com:youruser/lgtm-stack-experiment.git"
# git_access_key = "base64-encoded-ssh-key"
```

### data.tf

```hcl
# Get current AWS account and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Get VPC details
data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Get subnet details
data "aws_subnet" "selected" {
  id = var.subnet_id
}

# Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
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

# Get SSH key pair
data "aws_key_pair" "selected" {
  key_name = var.ssh_key_name
}
```

### locals.tf

```hcl
locals {
  # Compute common values
  name_prefix = "${var.environment}-lgtm"

  # Merge common tags with environment-specific tags
  tags = merge(
    var.common_tags,
    {
      Environment = var.environment
      Name        = "${local.name_prefix}-stack"
    }
  )

  # User data variables
  user_data_vars = {
    git_access_key = var.git_access_key
    git_repo_url   = var.git_repo_url
  }
}
```

### outputs.tf

```hcl
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.lgtm.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = aws_instance.lgtm.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = aws_instance.lgtm.private_ip
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.lgtm.id
}

output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.lgtm.public_ip}:${var.grafana_port}"
}

output "otlp_grpc_endpoint" {
  description = "OTLP gRPC endpoint"
  value       = "${aws_instance.lgtm.private_ip}:${var.otlp_grpc_port}"
}

output "otlp_http_endpoint" {
  description = "OTLP HTTP endpoint"
  value       = "http://${aws_instance.lgtm.private_ip}:${var.otlp_http_port}"
}

output "ssh_command" {
  description = "SSH command to connect to instance"
  value       = "ssh -i ~/.ssh/${var.ssh_key_name}.pem ec2-user@${aws_instance.lgtm.public_ip}"
}
```

---

## Module Design Patterns

### When to Create Modules

**Create a module when:**
- Code is used in multiple places (DRY principle)
- Resources form a logical unit (e.g., VPC networking, EC2 application)
- You want to share infrastructure patterns across teams
- Complexity needs abstraction

**Don't create a module when:**
- Wrapping a single resource with no abstraction
- Module would be used only once
- Adds unnecessary complexity

### Module Structure

```text
modules/lgtm-instance/
├── main.tf        # Primary resource definitions
├── variables.tf   # Input variables (required and optional)
├── outputs.tf     # Output values exposed by module
├── versions.tf    # Provider version constraints
├── README.md      # Module documentation
└── examples/      # Example usage
    └── basic/
        ├── main.tf
        └── variables.tf
```

### Example Module: lgtm-instance

**modules/lgtm-instance/variables.tf:**

```hcl
variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "ami_id" {
  description = "AMI ID (if not specified, uses latest Amazon Linux 2023)"
  type        = string
  default     = null
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR blocks allowed to SSH"
  type        = list(string)
  default     = []
}

variable "user_data" {
  description = "User data script"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
```

**modules/lgtm-instance/main.tf:**

```hcl
data "aws_ami" "amazon_linux_2023" {
  count = var.ami_id == null ? 1 : 0

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
}

locals {
  ami_id = var.ami_id != null ? var.ami_id : data.aws_ami.amazon_linux_2023[0].id

  default_tags = {
    Name        = var.name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  tags = merge(local.default_tags, var.tags)
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-"
  description = "Security group for ${var.name}"
  vpc_id      = var.vpc_id

  tags = local.tags
}

resource "aws_security_group_rule" "ssh" {
  count = length(var.allowed_ssh_cidr) > 0 ? 1 : 0

  type              = "ingress"
  security_group_id = aws_security_group.this.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.allowed_ssh_cidr
  description       = "SSH access"
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  security_group_id = aws_security_group.this.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow all outbound"
}

resource "aws_instance" "this" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  key_name                    = var.key_name
  associate_public_ip_address = true
  user_data                   = var.user_data

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  tags = local.tags
}
```

**modules/lgtm-instance/outputs.tf:**

```hcl
output "instance_id" {
  description = "Instance ID"
  value       = aws_instance.this.id
}

output "instance_public_ip" {
  description = "Public IP address"
  value       = aws_instance.this.public_ip
}

output "instance_private_ip" {
  description = "Private IP address"
  value       = aws_instance.this.private_ip
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.this.id
}
```

**Using the module (root main.tf):**

```hcl
module "lgtm_instance" {
  source = "./modules/lgtm-instance"

  name             = "lgtm"
  environment      = var.environment
  vpc_id           = var.vpc_id
  subnet_id        = var.subnet_id
  instance_type    = var.instance_type
  key_name         = var.ssh_key_name
  allowed_ssh_cidr = [var.ssh_ingress_cidr]

  user_data = templatefile("${path.module}/user_data.tpl", {
    git_access_key = var.git_access_key
    git_repo_url   = var.git_repo_url
  })

  tags = var.common_tags
}

output "grafana_url" {
  value = "http://${module.lgtm_instance.instance_public_ip}:3000"
}
```

---

## Variable and Output Best Practices

### Variable Patterns

**1. Use Type Constraints**

```hcl
# BAD - no type
variable "instance_type" {}

# GOOD - explicit type
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

# BETTER - validation
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"

  validation {
    condition     = contains(["t3.medium", "t3.large", "m6i.large"], var.instance_type)
    error_message = "Instance type must be t3.medium, t3.large, or m6i.large."
  }
}
```

**2. Use Complex Types**

```hcl
# Object type for structured data
variable "vpc_config" {
  description = "VPC configuration"
  type = object({
    vpc_id    = string
    subnet_id = string
    cidr      = string
  })
}

# Map for key-value pairs
variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

# List for multiple values
variable "allowed_cidrs" {
  description = "Allowed CIDR blocks"
  type        = list(string)
  default     = []
}
```

**3. Mark Sensitive Variables**

```hcl
variable "git_access_key" {
  description = "SSH deploy key for the git host"
  type        = string
  sensitive   = true  # Won't be shown in logs
}
```

**4. Provide Good Defaults**

```hcl
variable "monitoring_enabled" {
  description = "Enable CloudWatch detailed monitoring"
  type        = bool
  default     = true  # Sensible default
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"  # Good starting point
}
```

### Output Patterns

**1. Output Useful Information**

```hcl
# Output connection info
output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.lgtm.public_ip}"
}

# Output service URLs
output "grafana_url" {
  description = "Grafana dashboard URL"
  value       = "http://${aws_instance.lgtm.public_ip}:3000"
}

# Output resource IDs for other modules
output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.lgtm.id
}
```

**2. Mark Sensitive Outputs**

```hcl
output "database_password" {
  description = "Database password"
  value       = random_password.db.result
  sensitive   = true  # Won't be shown in terraform output
}
```

**3. Output for Debugging**

```hcl
output "debug_info" {
  description = "Debug information"
  value = {
    ami_id         = data.aws_ami.amazon_linux_2023.id
    ami_name       = data.aws_ami.amazon_linux_2023.name
    vpc_cidr       = data.aws_vpc.selected.cidr_block
    subnet_az      = data.aws_subnet.selected.availability_zone
  }
}
```

---

## Terraform Workflow and Commands

### Standard Workflow

```bash
# 1. Initialize Terraform (first time or after backend changes)
terraform init

# 2. Validate configuration syntax
terraform validate

# 3. Format code consistently
terraform fmt -recursive

# 4. Plan changes (preview)
terraform plan -out=tfplan

# 5. Apply changes
terraform apply tfplan

# 6. Show current state
terraform show

# 7. List resources in state
terraform state list

# 8. Destroy infrastructure (use with caution!)
terraform destroy
```

### Useful Commands

```bash
# Validate configuration without accessing remote state
terraform validate

# Format all .tf files in directory tree
terraform fmt -recursive

# Show execution plan in JSON format
terraform show -json tfplan | jq

# Refresh state without modifying infrastructure
terraform refresh

# Import existing resource
terraform import aws_instance.lgtm i-1234567890abcdef

# Remove resource from state (without destroying)
terraform state rm aws_instance.lgtm

# Move resource in state
terraform state mv aws_instance.old aws_instance.new

# Taint resource (force recreation)
terraform taint aws_instance.lgtm

# Untaint resource
terraform untaint aws_instance.lgtm

# Get output value
terraform output grafana_url

# Get all outputs as JSON
terraform output -json

# Replace a resource (destroy and recreate)
terraform apply -replace="aws_instance.lgtm"
```

---

## GitOps and CI/CD Integration

### Git Best Practices

**1. .gitignore for Terraform**

```gitignore
# Local .terraform directories
**/.terraform/*

# .tfstate files (use remote state instead)
*.tfstate
*.tfstate.*

# Crash log files
crash.log
crash.*.log

# Exclude all .tfvars files (may contain secrets)
*.tfvars
*.tfvars.json

# Override files (personal local overrides)
override.tf
override.tf.json
*_override.tf
*_override.tf.json

# CLI configuration files
.terraformrc
terraform.rc

# Plan files
*.tfplan
tfplan

# Ignore Mac .DS_Store files
.DS_Store

# Ignore lock file (or commit it for consistency)
# .terraform.lock.hcl
```

**2. Commit terraform.lock.hcl**

```bash
# DO commit lock file for consistent provider versions
git add .terraform.lock.hcl
git commit -m "Update provider versions"
```

### CI/CD Pipeline Pattern (GitHub Actions)

**.github/workflows/terraform.yml:**

```yaml
name: Terraform

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  AWS_REGION: us-east-1
  TF_VERSION: 1.9.0

jobs:
  terraform:
    name: Terraform Plan/Apply
    runs-on: ubuntu-latest

    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check -recursive
        continue-on-error: true

      - name: Terraform Init
        id: init
        run: terraform init

      - name: Terraform Validate
        id: validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -out=tfplan
        continue-on-error: true

      - name: Comment PR with Plan
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v6
        with:
          script: |
            const output = `#### Terraform Format and Style 🖌\`${{ steps.fmt.outcome }}\`
            #### Terraform Initialization ⚙️\`${{ steps.init.outcome }}\`
            #### Terraform Validation 🤖\`${{ steps.validate.outcome }}\`
            #### Terraform Plan 📖\`${{ steps.plan.outcome }}\`

            <details><summary>Show Plan</summary>

            \`\`\`terraform
            ${{ steps.plan.outputs.stdout }}
            \`\`\`

            </details>

            *Pushed by: @${{ github.actor }}, Action: \`${{ github.event_name }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve tfplan
```

### Pre-commit Hooks

**Install pre-commit:**

```bash
pip install pre-commit
```

**.pre-commit-config.yaml:**

```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.83.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_docs
      - id: terraform_tflint
      - id: terraform_tfsec

  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.4.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
```

**Install hooks:**

```bash
pre-commit install
pre-commit run --all-files
```

---

## Testing and Validation

### Syntax and Configuration Testing

**1. Built-in Validation**

```bash
# Validate configuration syntax
terraform validate

# Format check
terraform fmt -check -recursive

# Show plan without applying
terraform plan
```

**2. TFLint (Linting)**

```bash
# Install TFLint
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# Initialize plugins
tflint --init

# Run linter
tflint
```

**.tflint.hcl:**

```hcl
plugin "aws" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}
```

**3. TFSec (Security Scanning)**

```bash
# Install tfsec
brew install tfsec  # macOS
# or
curl -s https://raw.githubusercontent.com/aquasecurity/tfsec/master/scripts/install_linux.sh | bash

# Run security scan
tfsec .

# Output as JSON
tfsec . --format json > tfsec-report.json
```

### Integration Testing

**Terratest (Go-based testing):**

**tests/lgtm_test.go:**

```go
package test

import (
    "testing"
    "github.com/gruntwork-io/terratest/modules/terraform"
    "github.com/stretchr/testify/assert"
)

func TestLGTMInstance(t *testing.T) {
    terraformOptions := &terraform.Options{
        TerraformDir: "../",
        Vars: map[string]interface{}{
            "environment":     "test",
            "vpc_id":          "vpc-test123",
            "subnet_id":       "subnet-test123",
            "instance_type":   "t3.micro",
        },
    }

    defer terraform.Destroy(t, terraformOptions)
    terraform.InitAndApply(t, terraformOptions)

    instanceID := terraform.Output(t, terraformOptions, "instance_id")
    assert.NotEmpty(t, instanceID)

    publicIP := terraform.Output(t, terraformOptions, "instance_public_ip")
    assert.NotEmpty(t, publicIP)
}
```

---

## Summary and Quick Reference

### Essential Best Practices

1. **Use remote state** with S3 backend and locking
2. **Version control everything** except secrets
3. **Separate environments** (dev/staging/prod)
4. **Use modules** for reusable components
5. **Tag all resources** consistently
6. **Use data sources** for existing infrastructure
7. **Validate before apply** with terraform plan
8. **Enable state encryption** with KMS
9. **Implement CI/CD** for automated testing
10. **Document modules** with README files

### Current Project Improvements

**High Priority:**
1. Add remote state backend (S3 + native locking)
2. Separate variables into variables.tf
3. Add outputs.tf for useful information
4. Create terraform.tfvars.example
5. Add .gitignore for Terraform files

**Medium Priority:**
6. Split resources into separate files (ec2.tf, security_groups.tf)
7. Add validation to variables
8. Implement proper tagging strategy
9. Create reusable modules
10. Add pre-commit hooks

**Low Priority:**
11. Set up CI/CD pipeline
12. Add Terratest integration tests
13. Implement workspaces for environments
14. Document with terraform-docs

### Quick Migration Path

```bash
# 1. Create backend configuration
cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket       = "example-terraform-state"
    key          = "lgtm-stack/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
EOF

# 2. Migrate to remote state
terraform init -migrate-state

# 3. Split files
# Move variables to variables.tf
# Move outputs to outputs.tf
# Move data sources to data.tf

# 4. Format and validate
terraform fmt -recursive
terraform validate

# 5. Test with plan
terraform plan

# 6. Commit changes
git add .
git commit -m "Migrate to remote state and modular structure"
```
