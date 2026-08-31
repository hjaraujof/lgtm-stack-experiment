# =============================================================================
# THE FILE THAT REMOVES EVERY STATIC CREDENTIAL FROM THE CLUSTER
# =============================================================================
# One IAM role, reached two ways. var.use_pod_identity picks which.
#
#   EKS Pod Identity (default)  AWS's current recommendation for a new EKS
#                               cluster. The role trusts one service principal,
#                               and an association binds it to a namespace and a
#                               ServiceAccount name. No OIDC provider exists, no
#                               per-cluster trust policy exists, and the Helm
#                               chart needs no annotation.
#
#   IRSA                        The portable one. It works with any OIDC
#                               provider, across accounts, and outside EKS. It
#                               needs an OIDC provider and a trust policy that
#                               names the exact ServiceAccount, and the chart
#                               needs the eks.amazonaws.com/role-arn annotation.
#
# BOTH ARE THE SAME SECURITY TIER: no key exists in the cluster either way. The
# credential is a short-lived token that AWS issues to one ServiceAccount and
# rotates by itself. Choose on portability, not on safety.
#
# WHAT NEITHER OF THEM IS. Neither is an access key in a Kubernetes Secret, and
# neither is the node role. Attaching this policy to the node role would work
# immediately and would grant the bucket to EVERY pod on the node, because any
# pod can read the instance metadata service.

locals {
  role_name = "${var.cluster_name}-telemetry"

  # Read, write, delete, list. DeleteObject is required: without it compaction
  # cannot remove the source blocks it has just merged, so the bucket grows
  # forever while compaction reports success.
  bucket_actions = [
    "s3:GetObject",
    "s3:PutObject",
    "s3:DeleteObject",
    "s3:ListBucket",
    "s3:AbortMultipartUpload",
  ]
}

# -----------------------------------------------------------------------------
# IRSA only: the cluster's OIDC provider
# -----------------------------------------------------------------------------
data "tls_certificate" "oidc" {
  count = var.use_pod_identity ? 0 : 1
  url   = aws_eks_cluster.lgtm.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  count = var.use_pod_identity ? 0 : 1

  url             = aws_eks_cluster.lgtm.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc[0].certificates[0].sha1_fingerprint]
}

# -----------------------------------------------------------------------------
# The role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "trust" {
  dynamic "statement" {
    # Pod Identity: the trust is a plain service principal. The BINDING to a
    # ServiceAccount lives in the association resource below, not here, which is
    # why this policy is short and reusable across clusters.
    for_each = var.use_pod_identity ? [1] : []
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:TagSession"]
      principals {
        type        = "Service"
        identifiers = ["pods.eks.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    # IRSA: the trust names the exact ServiceAccount through an OIDC condition.
    #
    # THE `sub` CONDITION IS THE WHOLE SECURITY BOUNDARY. With StringLike and a
    # wildcard, or with the condition omitted, ANY ServiceAccount in the cluster
    # could assume this role. StringEquals against the one subject is what makes
    # the role belong to one workload.
    for_each = var.use_pod_identity ? [] : [1]
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [aws_iam_openid_connect_provider.cluster[0].arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${replace(aws_iam_openid_connect_provider.cluster[0].url, "https://", "")}:sub"
        values   = ["system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"]
      }
      # WITHOUT THIS SECOND CONDITION the token's audience is unchecked, and a
      # token minted for a different audience would be accepted.
      condition {
        test     = "StringEquals"
        variable = "${replace(aws_iam_openid_connect_provider.cluster[0].url, "https://", "")}:aud"
        values   = ["sts.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role" "telemetry" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# SCOPED TO TWO BUCKETS BY ARN. Not s3:* and not "Resource": "*". A telemetry
# backend that can read every bucket in the account is one compromised container
# away from being an exfiltration path.
data "aws_iam_policy_document" "buckets" {
  statement {
    sid       = "TracesBucket"
    effect    = "Allow"
    actions   = local.bucket_actions
    resources = [aws_s3_bucket.traces.arn, "${aws_s3_bucket.traces.arn}/*"]
  }

  statement {
    sid       = "MetricsBucket"
    effect    = "Allow"
    actions   = local.bucket_actions
    resources = [aws_s3_bucket.metrics.arn, "${aws_s3_bucket.metrics.arn}/*"]
  }

  # The Secrets Store CSI driver reads the Grafana passwords with this same
  # identity. ONE SECRET BY ARN - a wildcard here would hand every secret in the
  # account to a telemetry pod.
  statement {
    sid       = "ReadGrafanaSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:/example/dev/lgtm-stack-*"]
  }
}

resource "aws_iam_role_policy" "buckets" {
  name   = "${local.role_name}-s3"
  role   = aws_iam_role.telemetry.id
  policy = data.aws_iam_policy_document.buckets.json
}

# -----------------------------------------------------------------------------
# Pod Identity only: the association
# -----------------------------------------------------------------------------
# THIS IS THE BINDING. Without it the role exists, trusts the EKS service, and
# is attached to nothing. The failure is a plain AccessDenied from S3 with no
# hint that the association is missing.
resource "aws_eks_pod_identity_association" "telemetry" {
  count = var.use_pod_identity ? 1 : 0

  cluster_name    = aws_eks_cluster.lgtm.name
  namespace       = var.service_account_namespace
  service_account = var.service_account_name
  role_arn        = aws_iam_role.telemetry.arn
}
