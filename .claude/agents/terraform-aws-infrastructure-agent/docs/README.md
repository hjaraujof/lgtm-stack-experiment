# Terraform AWS Infrastructure Agent Documentation

## Overview

This documentation provides comprehensive reference material for the Terraform AWS Infrastructure Agent. The agent uses this documentation to provide expert guidance on AWS infrastructure patterns, Terraform best practices, and security hardening for the LGTM observability stack.

**Documentation Coverage:** 4,200+ lines across 4 comprehensive guides

---

## Documentation Structure

### 01. EC2 Configuration Patterns
**File:** `01-ec2-configuration.md`
**Lines:** 737
**Focus:** EC2 instance configuration, sizing, AMI selection, user data, and cloud-init

**Key Topics:**
- Instance sizing for observability workloads (LGTM stack)
- AMI selection patterns and lifecycle management
- User data and cloud-init best practices
- Troubleshooting user data scripts
- Instance metadata options (IMDSv2)
- EBS volume configuration and optimization
- CloudWatch monitoring integration
- SSH access and key management
- Resource tagging strategies

**When to Use:**
- Sizing instances for Grafana, Loki, Tempo, Mimir workloads
- Configuring user data for automated instance bootstrapping
- Troubleshooting startup scripts
- Optimizing EBS volumes for cost and performance
- Implementing security hardening (IMDSv2, encryption)

---

### 02. Security Patterns
**File:** `02-security-patterns.md`
**Lines:** 1,014
**Focus:** Security groups, IAM roles, Secrets Manager, encryption, and compliance

**Key Topics:**
- Security group design patterns (least privilege)
- Separating security groups by function
- IAM roles and instance profiles
- Secrets Manager integration
- Encryption best practices (EBS, KMS)
- Network security patterns (private subnets, VPC endpoints)
- Security monitoring (CloudTrail, GuardDuty, Security Hub)
- Access control and auditing

**When to Use:**
- Implementing least privilege security groups
- Setting up IAM instance profiles for AWS API access
- Securely managing secrets and credentials
- Hardening infrastructure against common threats
- Meeting compliance requirements (CIS benchmarks)
- Implementing defense-in-depth strategies

---

### 03. Networking Patterns
**File:** `03-networking-patterns.md`
**Lines:** 1,075
**Focus:** VPC, subnets, NAT gateways, load balancers, and DNS

**Key Topics:**
- Public vs private subnet selection
- Subnet selection patterns (by tag, ID, AZ)
- NAT Gateway patterns (single, multi-AZ, NAT instances)
- Application Load Balancer (ALB) for Grafana
- Network Load Balancer (NLB) for OTLP endpoints
- Architecture evolution patterns (simple → HA)
- VPC peering and PrivateLink
- Route 53 DNS integration
- Cost optimization for networking

**When to Use:**
- Choosing between public and private subnets
- Implementing high availability across multiple AZs
- Setting up load balancers for Grafana and OTLP
- Designing secure network architectures
- Optimizing networking costs
- Connecting multiple VPCs or services

---

### 04. Terraform Best Practices
**File:** `04-terraform-best-practices.md`
**Lines:** 1,383
**Focus:** State management, code organization, modules, CI/CD, and testing

**Key Topics:**
- Remote state with S3 (native locking)
- State locking (S3 native vs DynamoDB)
- Code organization and file structure
- Module design patterns
- Variable and output best practices
- GitOps and CI/CD integration
- Pre-commit hooks and validation
- Testing with TFLint, TFSec, Terratest
- Workflow and command reference

**When to Use:**
- Setting up remote state for team collaboration
- Organizing Terraform code for maintainability
- Creating reusable infrastructure modules
- Implementing CI/CD pipelines for Terraform
- Ensuring code quality and security
- Migrating from local to remote state

---

## Current LGTM Stack Analysis

### Existing Configuration

The current `main.tf` configuration:
- **Lines:** 151
- **Resources:** EC2 instance, security group
- **Data Sources:** VPC, subnet, AMI, key pair, Secrets Manager
- **State:** Local (not remote)
- **Structure:** Single file

**Strengths:**
- Uses data sources for existing infrastructure (VPC, subnet)
- Retrieves secrets from Secrets Manager
- Uses Amazon Linux 2023 AMI with proper filters
- Restricts OTLP endpoints to VPC CIDR
- Restricts SSH to specific CIDR block

**Improvement Opportunities:**
1. No remote state backend (team collaboration limited)
2. No IAM instance profile (credentials in user data)
3. Missing IMDSv2 enforcement
4. No EBS volume encryption configuration
5. Grafana exposed to entire internet (0.0.0.0/0)
6. Single security group (not separated by function)
7. Single file structure (difficult to navigate)
8. No variable validation
9. No outputs defined
10. Single AZ deployment (no HA)

---

## Priority Recommendations

### High Priority (Immediate)

**1. Add Remote State Backend**
- Enables team collaboration
- Prevents concurrent modifications
- Provides state versioning and backup
- **Documentation:** `04-terraform-best-practices.md` → State Management

**2. Add IAM Instance Profile**
- Replace hardcoded credentials in user data
- Secure access to Secrets Manager
- Enable CloudWatch monitoring
- **Documentation:** `02-security-patterns.md` → IAM Roles

**3. Enforce IMDSv2**
- Prevent SSRF attacks
- Security best practice
- **Documentation:** `01-ec2-configuration.md` → Metadata Options

**4. Enable EBS Encryption**
- Account-wide encryption by default
- Encrypt root volume
- **Documentation:** `02-security-patterns.md` → Encryption

**5. Separate Configuration Files**
- Split into variables.tf, outputs.tf, data.tf
- Improve maintainability
- **Documentation:** `04-terraform-best-practices.md` → Code Organization

---

### Medium Priority (Next Sprint)

**6. Add Application Load Balancer for Grafana**
- SSL termination
- Restrict instance security group to ALB only
- **Documentation:** `03-networking-patterns.md` → ALB Patterns

**7. Move Instance to Private Subnet**
- Add NAT Gateway for outbound
- Improve security posture
- **Documentation:** `03-networking-patterns.md` → Public vs Private

**8. Separate Security Groups by Function**
- Grafana, OTLP, Backends, SSH
- Better isolation and auditing
- **Documentation:** `02-security-patterns.md` → Security Group Patterns

**9. Enable Detailed CloudWatch Monitoring**
- 1-minute metric intervals
- Better observability
- **Documentation:** `01-ec2-configuration.md` → Monitoring

**10. Add Restrictive Egress Rules**
- Only allow necessary outbound traffic
- Defense in depth
- **Documentation:** `02-security-patterns.md` → Security Groups

---

### Low Priority (Future)

**11. Implement Multi-AZ High Availability**
- Auto Scaling Group
- Multi-AZ NAT Gateways
- **Documentation:** `03-networking-patterns.md` → Architecture Patterns

**12. Add VPC Endpoints**
- Avoid internet for AWS API calls
- Improve security and performance
- **Documentation:** `02-security-patterns.md` → VPC Endpoints

**13. Create Reusable Modules**
- Extract to modules/lgtm-instance
- Enable reuse across environments
- **Documentation:** `04-terraform-best-practices.md` → Module Design

**14. Implement CI/CD Pipeline**
- Automated validation and deployment
- GitHub Actions or GitLab CI
- **Documentation:** `04-terraform-best-practices.md` → CI/CD

**15. Add Testing and Validation**
- TFLint, TFSec, Terratest
- Pre-commit hooks
- **Documentation:** `04-terraform-best-practices.md` → Testing

---

## Quick Reference

### Common Scenarios

**Scenario: "How do I size EC2 for LGTM stack?"**
- **Document:** `01-ec2-configuration.md` → Instance Sizing
- **Answer:** Start with t3.large for dev, m6i.large for prod

**Scenario: "How do I secure Grafana access?"**
- **Document:** `03-networking-patterns.md` → ALB Patterns
- **Answer:** Use ALB with SSL, restrict instance SG to ALB only

**Scenario: "How do I set up remote state?"**
- **Document:** `04-terraform-best-practices.md` → Remote State
- **Answer:** Use S3 backend with native locking (use_lockfile = true)

**Scenario: "How do I restrict security group rules?"**
- **Document:** `02-security-patterns.md` → Least Privilege
- **Answer:** Separate SGs by function, use source SG references

**Scenario: "How do I troubleshoot user data?"**
- **Document:** `01-ec2-configuration.md` → User Data Troubleshooting
- **Answer:** Check /var/log/cloud-init-output.log

---

## Architecture Evolution Path

### Phase 1: Current (Simple)
- Single EC2 in public subnet
- Direct Grafana access (0.0.0.0/0)
- VPC-scoped OTLP
- Local state
- **Cost:** ~$20/month

### Phase 2: Secured (Recommended Next Step)
- ALB for Grafana (SSL)
- EC2 in private subnet
- NAT Gateway for outbound
- Remote state (S3 + locking)
- IAM instance profile
- **Cost:** ~$75/month

### Phase 3: Highly Available (Production)
- Multi-AZ ALB and NLB
- Auto Scaling Group (2+ instances)
- NAT Gateway per AZ
- VPC endpoints
- CloudWatch detailed monitoring
- **Cost:** ~$200/month

---

## How to Use This Documentation

### For Initial Setup
1. Read `04-terraform-best-practices.md` for state management
2. Read `01-ec2-configuration.md` for instance sizing
3. Read `02-security-patterns.md` for security hardening
4. Read `03-networking-patterns.md` for network design

### For Specific Problems
- Use the Quick Reference section above
- Search within specific documents for keywords
- Check the "When to Use" sections at the start of each document

### For Architecture Design
1. Start with `03-networking-patterns.md` → Architecture Patterns
2. Review `02-security-patterns.md` for security considerations
3. Check `01-ec2-configuration.md` for instance configuration
4. Implement with patterns from `04-terraform-best-practices.md`

---

## Additional Resources

### External Documentation
- Terraform AWS Provider: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- AWS Well-Architected: https://aws.amazon.com/architecture/well-architected/
- AWS VPC Guide: https://docs.aws.amazon.com/vpc/
- Terraform Best Practices: https://www.terraform-best-practices.com/

### Current Stack Documentation
- Main CLAUDE.md: `.claude/CLAUDE.md`
- Current main.tf: `main.tf`
- User data template: `user_data.tpl`

---

## Document Maintenance

**Last Updated:** 2025-11-28

**Research Sources:**
- AWS Prescriptive Guidance
- HashiCorp Terraform Documentation
- AWS Well-Architected Framework
- Grafana Cloud Documentation
- Industry best practices (2024-2025)

**Agent Usage:**
This documentation is used by the terraform-aws-infrastructure-agent to provide expert guidance on:
- Infrastructure design decisions
- Security hardening recommendations
- Cost optimization strategies
- High availability patterns
- Terraform code improvements
- Troubleshooting and debugging

The agent combines this documentation with analysis of the current configuration to provide specific, actionable recommendations.
