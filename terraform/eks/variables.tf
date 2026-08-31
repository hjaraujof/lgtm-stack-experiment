# Non-secret configuration for the Kubernetes plane.
#
# Every value carries a placeholder default so `tofu plan` runs on a fresh
# checkout. Override them in a gitignored terraform.tfvars or with -var.

variable "region" {
  description = "AWS region for the cluster and its buckets."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name. Also the prefix for the IAM roles below."
  type        = string
  default     = "lgtm"
}

variable "kubernetes_version" {
  description = "EKS control-plane version. AWS supports each version for a limited window, so this is a recurring maintenance item, not a set-and-forget value."
  type        = string
  default     = "1.32"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC this module creates. It creates its OWN VPC rather than reusing the one in the root module, so destroying one plane cannot affect the other."
  type        = string
  default     = "10.20.0.0/16"
}

variable "node_instance_type" {
  description = "Instance type for the managed node group. Loki, Tempo and Mimir are memory-hungry; the CLAUDE.md sizing table treats 16 GB as the practical floor for the whole stack on one host, and the same arithmetic applies per node here."
  type        = string
  default     = "t3a.xlarge"
}

variable "node_desired_size" {
  description = "Node count. Three keeps the DaemonSet lesson honest and gives the scheduler somewhere to move a pod."
  type        = number
  default     = 3
}

variable "node_min_size" {
  type        = number
  description = "Minimum node count."
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum node count."
  default     = 5
}

# =============================================================================
# THE IDENTITY DECISION
# =============================================================================
variable "use_pod_identity" {
  description = <<-EOT
    true  -> EKS Pod Identity. AWS's current recommendation for a new EKS
             cluster. The role trusts the pods.eks.amazonaws.com service
             principal, and an association object binds it to a Kubernetes
             ServiceAccount. No OIDC provider and no per-cluster trust policy.
             The chart needs NO annotation. EKS only.

    false -> IRSA. The portable one: it works with any OIDC provider, across
             accounts, and outside EKS. It needs an OIDC provider and a trust
             policy naming the exact ServiceAccount, and the chart needs the
             eks.amazonaws.com/role-arn annotation.

    BOTH ARE TIER 5: no static credential exists in the cluster in either case.
    Choose on portability, not on security.
  EOT
  type        = bool
  default     = true
}

variable "service_account_namespace" {
  description = "Namespace the chart is installed into. It must match `helm install -n`, because the identity binding names it exactly."
  type        = string
  default     = "lgtm"
}

variable "service_account_name" {
  description = "ServiceAccount the chart creates. The chart builds this from the release name as <release>-lgtm, so a release named something else needs this changed to match. A mismatch does not fail the apply - the pods simply get no AWS identity and the S3 calls fail at runtime."
  type        = string
  default     = "lgtm-lgtm"
}

# =============================================================================
# OBJECT STORAGE
# =============================================================================
variable "trace_retention_days" {
  description = "S3 lifecycle expiration for trace blocks. A backstop against a stalled compactor, so it must EXCEED Tempo's own block_retention (72h) plus a compaction window."
  type        = number
  default     = 5
}

variable "metric_retention_days" {
  description = "S3 lifecycle expiration for metric blocks. Must exceed Mimir's compactor_blocks_retention_period (336h = 14 days) plus a buffer."
  type        = number
  default     = 16
}
