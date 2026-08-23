# EC2 Configuration Patterns

## Overview

This document provides comprehensive guidance on AWS EC2 instance configuration using Terraform, with specific focus on observability workloads (LGTM stack: Loki, Grafana, Tempo, Mimir).

---

## Instance Sizing for Observability Workloads

### General Recommendations

**For development/testing:**
- Instance Type: `t3.medium` or `t3.large`
- vCPU: 2-4
- Memory: 4-8 GB
- Network: Up to 5 Gbps

**For production:**
- Instance Type: `m6i.large` or `m6i.xlarge` (compute optimized)
- vCPU: 4-8
- Memory: 16-32 GB
- Network: Up to 12.5 Gbps

**For high-throughput production:**
- Instance Type: `c6i.2xlarge` or storage-optimized instances
- Consider EBS-optimized instance families (M5, C5, M6i)
- For high I/O workloads, consider storage-optimized families (I3, D2)

### Current Stack Analysis

The LGTM stack in this repository runs:
- **Grafana** - Visualization (relatively lightweight)
- **Loki** - Log aggregation (memory intensive for queries)
- **Tempo** - Distributed tracing (I/O intensive)
- **Mimir** - Prometheus-compatible metrics (CPU and memory intensive)
- **OTel Collector** - Data ingestion pipeline

**Recommendation:** Start with `t3.large` for dev, `m6i.large` for production. Monitor CloudWatch metrics and scale up if:
- CPU utilization consistently >70%
- Memory utilization >80%
- Disk I/O wait times increase
- Query response times degrade

---

## AMI Selection Patterns

### Current Configuration

```hcl
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
```

### Best Practices

**1. Always Use Filters for Specificity**
- Filter by `architecture` (x86_64 or arm64)
- Filter by `virtualization-type` (always use "hvm" for modern instances)
- Filter by `root-device-type` (prefer "ebs" for persistence)
- Filter by `state` (available) to exclude deprecated AMIs

**2. Use `most_recent = true` with Caution**
- Benefits: Automatic security patches and updates
- Risks: Unexpected changes, breaking changes in new AMI versions
- Recommendation: Use `most_recent = true` for dev/staging, pin specific AMI IDs for production

**3. AMI Lifecycle Management**
```hcl
# Development - auto-update
data "aws_ami" "dev_ami" {
  most_recent = true
  owners      = ["amazon"]
  # ... filters
}

# Production - pinned version with explicit update process
resource "aws_instance" "prod" {
  ami = "ami-0123456789abcdef0"  # Pinned, updated via change management
  # ... other config
}
```

**4. Amazon Linux 2023 Advantages**
- Long-term support through 2028
- Optimized for AWS with AWS CLI pre-installed
- Regular security updates
- Better container support
- Modern systemd and kernel

**5. Alternative AMI Sources**
```hcl
# Ubuntu (for broader package availability)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Container-optimized (ECS-optimized)
data "aws_ami" "ecs_optimized" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-ecs-hvm-*"]
  }
}
```

---

## User Data and Cloud-Init

### Current Configuration Analysis

The repository uses a `user_data.tpl` template file that:
1. Installs Docker and Docker Compose
2. Configures SSH access for Git
3. Clones the LGTM stack repository
4. Starts the Docker Compose stack

### User Data Best Practices

**1. Script Structure**
```bash
#!/bin/bash
# ALWAYS start with shebang
set -e  # Exit on error
set -x  # Enable debug output (logs all commands)

# Set HOME explicitly (important for ec2-user operations)
export HOME="/home/ec2-user"

# Log everything to a file for troubleshooting
exec > >(tee /var/log/user-data.log) 2>&1
echo "User data script started at $(date)"

# Your bootstrap logic here...

echo "User data script completed at $(date)"
```

**2. Error Handling**
```bash
# Check command success
if ! sudo yum update -y; then
    echo "ERROR: Failed to update packages" >&2
    exit 1
fi

# Use functions for reusable logic
function install_docker() {
    echo "Installing Docker..."
    sudo yum install -y docker || return 1
    sudo systemctl start docker || return 1
    sudo systemctl enable docker || return 1
}

install_docker || {
    echo "ERROR: Docker installation failed" >&2
    exit 1
}
```

**3. IAM Instance Profile Pattern**
```hcl
# Instead of embedding credentials in user data, use IAM roles
resource "aws_iam_role" "lgtm_instance_role" {
  name = "lgtm-instance-role"

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
}

resource "aws_iam_role_policy_attachment" "secrets_manager_read" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_instance_profile" "lgtm_profile" {
  name = "lgtm-instance-profile"
  role = aws_iam_role.lgtm_instance_role.name
}

resource "aws_instance" "lgtm_instance" {
  # ... other config
  iam_instance_profile = aws_iam_instance_profile.lgtm_profile.name
}
```

**4. Using AWS Secrets Manager from User Data**
```bash
#!/bin/bash
# Fetch secrets using IAM instance profile (no hardcoded credentials)
SECRET_VALUE=$(aws secretsmanager get-secret-value \
    --secret-id "/example/dev/lgtm-stack" \
    --region us-east-1 \
    --query SecretString \
    --output text)

# Parse JSON secret
SSH_KEY=$(echo "$SECRET_VALUE" | jq -r '.git_access_key')
REPO_URL=$(echo "$SECRET_VALUE" | jq -r '.git_repo_url')
```

**5. Terraform templatefile() Function**
```hcl
# Current pattern (GOOD)
user_data = templatefile("${path.module}/user_data.tpl", {
  git_access_key = local.secrets.git_access_key
  git_repo_url   = local.secrets.git_repo_url
})

# For complex configurations, consider cloud-init format
user_data = templatefile("${path.module}/cloud-init.yaml", {
  docker_compose_url = "https://..."
  monitoring_endpoint = "https://..."
})
```

**6. Cloud-Init Multi-Part Format**
```yaml
#cloud-config
# More structured alternative to bash scripts

packages:
  - docker
  - git
  - amazon-cloudwatch-agent

runcmd:
  - systemctl start docker
  - systemctl enable docker
  - usermod -a -G docker ec2-user
  - |
    aws secretsmanager get-secret-value \
      --secret-id /example/dev/lgtm-stack \
      --region us-east-1 --query SecretString --output text > /tmp/secrets.json
  - su - ec2-user -c "git clone $(jq -r .repo_url /tmp/secrets.json) /home/ec2-user/lgtm_stack"
  - cd /home/ec2-user/lgtm_stack && docker compose up -d

write_files:
  - path: /etc/systemd/system/lgtm-stack.service
    content: |
      [Unit]
      Description=LGTM Stack
      After=docker.service
      Requires=docker.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      WorkingDirectory=/home/ec2-user/lgtm_stack
      ExecStart=/usr/local/bin/docker-compose up -d
      ExecStop=/usr/local/bin/docker-compose down

      [Install]
      WantedBy=multi-user.target
```

---

## User Data Troubleshooting

### Log Locations

**Primary logs:**
```bash
# Cloud-init logs
/var/log/cloud-init.log           # Detailed cloud-init execution log
/var/log/cloud-init-output.log    # Console output from scripts

# User data script location
/var/lib/cloud/instances/<instance-id>/user-data.txt  # Raw user data
/var/lib/cloud/instances/<instance-id>/scripts/       # Executed scripts
```

**Check if script executed:**
```bash
# Search for script execution in logs
tail -n 1000 /var/log/cloud-init.log | grep "part-001"

# Check for errors
grep -i error /var/log/cloud-init-output.log
grep -i fail /var/log/cloud-init-output.log
```

### Common Issues

**Issue 1: Script runs only on first boot**
```bash
# Cloud-init runs user data once by default
# To re-run after modification:
sudo cloud-init clean
sudo cloud-init init
sudo cloud-init modules --mode=config
sudo cloud-init modules --mode=final
```

**Issue 2: Commands require user interaction**
```bash
# BAD - requires confirmation
yum update

# GOOD - non-interactive
yum update -y
```

**Issue 3: Permissions and ownership**
```bash
# Scripts run as root - files created are root-owned
# Fix ownership for ec2-user
sudo -u ec2-user mkdir -p /home/ec2-user/.ssh
sudo -u ec2-user chmod 700 /home/ec2-user/.ssh

# Or use chown after creation
mkdir /home/ec2-user/app
chown -R ec2-user:ec2-user /home/ec2-user/app
```

**Issue 4: Network not ready**
```bash
# Wait for network before critical operations
until ping -c1 google.com &>/dev/null; do
    echo "Waiting for network..."
    sleep 5
done

# Or use cloud-init's built-in network wait
#cloud-config
bootcmd:
  - cloud-init-per instance wait-for-network sh -c 'until ping -c1 8.8.8.8; do sleep 1; done'
```

---

## Instance Configuration Best Practices

### 1. Metadata Options (IMDSv2)

**Security Hardening - Require IMDSv2:**
```hcl
resource "aws_instance" "lgtm_instance" {
  # ... other config

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # Require IMDSv2 (session tokens)
    http_put_response_hop_limit = 1           # Restrict metadata access
    instance_metadata_tags      = "enabled"   # Allow tag access via IMDS
  }
}
```

**Why IMDSv2?**
- Prevents SSRF attacks against instance metadata
- Requires session-oriented requests
- Industry best practice for security

### 2. Monitoring and Observability

**Enable Detailed Monitoring:**
```hcl
resource "aws_instance" "lgtm_instance" {
  # ... other config
  monitoring = true  # Enable CloudWatch detailed monitoring (1-min intervals)
}
```

**CloudWatch Agent IAM Policy:**
```hcl
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.lgtm_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
```

### 3. EBS Volume Configuration

**Root Volume Optimization:**
```hcl
resource "aws_instance" "lgtm_instance" {
  # ... other config

  root_block_device {
    volume_type           = "gp3"       # GP3 is 20% cheaper than GP2
    volume_size           = 50          # Size in GB
    iops                  = 3000        # GP3 baseline: 3000 IOPS
    throughput            = 125         # GP3 baseline: 125 MB/s
    encrypted             = true        # ALWAYS encrypt volumes
    delete_on_termination = true        # Clean up on instance termination

    tags = {
      Name = "lgtm-root-volume"
    }
  }
}
```

**Additional Data Volumes:**
```hcl
resource "aws_ebs_volume" "lgtm_data" {
  availability_zone = aws_instance.lgtm_instance.availability_zone
  size              = 100
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = {
    Name = "lgtm-data-volume"
  }
}

resource "aws_volume_attachment" "lgtm_data_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.lgtm_data.id
  instance_id = aws_instance.lgtm_instance.id
}
```

**Volume Type Selection:**
- **gp3**: Default choice (3000 IOPS, 125 MB/s baseline, 20% cheaper than gp2)
- **gp2**: Legacy, use gp3 instead
- **io2**: High-performance databases (up to 64,000 IOPS, 99.999% durability)
- **st1**: Throughput-optimized HDD (large sequential reads, 500 MB/s max)
- **sc1**: Cold HDD (infrequent access, lowest cost)

### 4. Instance Placement and Availability

**Single Instance (Current):**
```hcl
resource "aws_instance" "lgtm_instance" {
  ami                         = data.aws_ami.latest_linux_2.id
  instance_type               = local.secrets.instance_type
  subnet_id                   = data.aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.lgtm_sg.id]
  associate_public_ip_address = true

  # Disable API termination for production
  disable_api_termination = true

  tags = {
    Name = "lgtm-ec2-instance"
  }
}
```

**High Availability Pattern:**
```hcl
# Use Auto Scaling Group for HA
resource "aws_launch_template" "lgtm" {
  name_prefix   = "lgtm-"
  image_id      = data.aws_ami.latest_linux_2.id
  instance_type = local.secrets.instance_type

  user_data = base64encode(templatefile("${path.module}/user_data.tpl", {
    git_access_key = local.secrets.git_access_key
    git_repo_url   = local.secrets.git_repo_url
  }))

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.lgtm_sg.id]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.lgtm_profile.name
  }
}

resource "aws_autoscaling_group" "lgtm" {
  name                = "lgtm-asg"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1
  health_check_type   = "ELB"
  health_check_grace_period = 300
  vpc_zone_identifier = [data.aws_subnet.public_subnet.id]

  launch_template {
    id      = aws_launch_template.lgtm.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "lgtm-asg-instance"
    propagate_at_launch = true
  }
}
```

---

## SSH Access and Key Management

### Current Pattern Analysis

The current configuration uses:
```hcl
data "aws_key_pair" "lgtm_key" {
  key_name = local.secrets.ssh_public_key_pair_name
}

resource "aws_instance" "lgtm_instance" {
  # ...
  key_name = data.aws_key_pair.lgtm_key.key_name
}
```

### Best Practices

**1. Use Data Source for Existing Keys**
- Current approach is correct - references existing key pair
- Key pair managed outside Terraform (in AWS console or via AWS CLI)
- Avoids storing private keys in state file

**2. Alternative: Manage Key Pairs with Terraform**
```hcl
# Generate key pair with Terraform (stores public key in state)
resource "aws_key_pair" "lgtm_terraform_managed" {
  key_name   = "lgtm-terraform-key"
  public_key = file("~/.ssh/id_rsa.pub")  # Path to your public key
}
```

**3. SSH Bastion Pattern (for private subnets)**
```hcl
# Jump host for accessing private instances
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.latest_linux_2.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.lgtm_terraform_managed.key_name

  tags = {
    Name = "lgtm-bastion"
  }
}

# Bastion security group
resource "aws_security_group" "bastion_sg" {
  name_prefix = "lgtm-bastion-"
  vpc_id      = data.aws_vpc.example_connect_target_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.secrets.ssh_ingress_cidr]  # Restrict to office IP
    description = "SSH from office"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Then SSH: ssh -J ec2-user@bastion ec2-user@private-instance
```

---

## Resource Tagging Strategy

### Recommended Tags

```hcl
locals {
  common_tags = {
    Environment = "dev"
    Project     = "lgtm-stack"
    ManagedBy   = "terraform"
    Owner       = "devops-team"
    CostCenter  = "engineering"
  }
}

resource "aws_instance" "lgtm_instance" {
  # ... other config

  tags = merge(local.common_tags, {
    Name = "lgtm-ec2-instance"
    Role = "observability-stack"
  })
}
```

### Tag Enforcement with Provider Defaults

```hcl
provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Environment = "dev"
      ManagedBy   = "terraform"
      Project     = "lgtm-stack"
    }
  }
}
```

---

## Current Configuration Improvements

### Recommendations for main.tf

**1. Add Encryption by Default**
```hcl
# Enable EBS encryption by default at account level
resource "aws_ebs_encryption_by_default" "enabled" {
  enabled = true
}
```

**2. Add IAM Instance Profile**
```hcl
# Replace hardcoded secrets in user_data with IAM role
resource "aws_iam_role" "lgtm_instance_role" {
  name = "lgtm-instance-role"

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
}

resource "aws_iam_instance_profile" "lgtm_profile" {
  name = "lgtm-instance-profile"
  role = aws_iam_role.lgtm_instance_role.name
}
```

**3. Add IMDSv2 Enforcement**
```hcl
resource "aws_instance" "lgtm_instance" {
  # ... existing config

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}
```

**4. Enable Detailed Monitoring**
```hcl
resource "aws_instance" "lgtm_instance" {
  # ... existing config
  monitoring = true
}
```

**5. Add Root Volume Configuration**
```hcl
resource "aws_instance" "lgtm_instance" {
  # ... existing config

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 50
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }
}
```

---

## Summary

**Key Takeaways:**
1. Use GP3 volumes for cost savings (20% cheaper than GP2)
2. Always encrypt EBS volumes
3. Use IAM instance profiles instead of hardcoded credentials
4. Enforce IMDSv2 for security
5. Enable detailed CloudWatch monitoring
6. Use Amazon Linux 2023 for long-term support
7. Implement proper error handling and logging in user data scripts
8. Use data sources for existing infrastructure, resources for managed infrastructure
9. Tag all resources consistently for cost tracking and management
10. For production: use Auto Scaling Groups with Launch Templates for HA
