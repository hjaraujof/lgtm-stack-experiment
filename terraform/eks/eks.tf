# =============================================================================
# EKS cluster and one managed node group
# =============================================================================

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "lgtm" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = concat(aws_subnet.private[*].id, aws_subnet.public[*].id)
    # The public API endpoint stays on so `kubectl` and `helm` work from a
    # laptop. RESTRICT public_access_cidrs BEFORE THIS IS ANYTHING BUT AN
    # EXPERIMENT: an open API endpoint is authenticated, but it is also
    # reachable by every scanner on the internet.
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  # ENCRYPT THE SECRETS THAT DO EXIST. Nothing in the chart writes a Secret on
  # this plane, because the Secrets Store CSI driver mounts files instead. This
  # is defence in depth for everything else: a service-account token, a
  # cert-manager private key, an add-on's own Secret. Without it those sit in
  # etcd base64-encoded, which is not encryption.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # Control-plane logs into CloudWatch. `authenticator` and `audit` are the two
  # that answer "who did this", and they are the two nobody enables until the
  # day they are needed and are not there.
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # THE MODERN AUTH MODE. The old aws-auth ConfigMap is deprecated: it was a
  # single Kubernetes object whose corruption locked everyone out of the
  # cluster with no recovery path short of recreating it. API mode moves the
  # mapping into the EKS API, where IAM governs it.
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_kms_key" "eks" {
  description             = "Envelope encryption for ${var.cluster_name} Kubernetes secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# -----------------------------------------------------------------------------
# Node group
# -----------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# THE NODE ROLE GRANTS NO S3 ACCESS, DELIBERATELY. Attaching the bucket policy
# here would be the quick way to make Tempo and Mimir work, and it would give
# EVERY pod on the node that access, because any pod can reach the instance
# metadata service. The whole point of Pod Identity and IRSA is that the
# permission belongs to one ServiceAccount, not to the machine.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # The EBS CSI driver runs as a DaemonSet with the node role. Without this
    # policy every volumeClaimTemplate in the chart stays Pending forever, and
    # the error appears on the PersistentVolumeClaim, never on the pod.
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "lgtm" {
  cluster_name    = aws_eks_cluster.lgtm.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  # LGTM backends hold data on local disks. 100 GB per node, not the 20 GB
  # default, for the same reason the EC2 host runs 150 GB: an 8 GB root volume
  # filled and took the whole stack down.
  disk_size = 100

  update_config {
    max_unavailable = 1
  }

  # A node group replacement is destructive to anything on local disk. Ignoring
  # desired_size lets the cluster autoscaler move it without OpenTofu fighting
  # back on the next plan.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# -----------------------------------------------------------------------------
# Add-ons
# -----------------------------------------------------------------------------
# EACH OF THESE IS A CONTROLLER THE CHART ASSUMES EXISTS AND CANNOT INSTALL.
# aws-ebs-csi-driver is the one that fails most confusingly: without it the pods
# stay Pending with no pod-level error at all.
resource "aws_eks_addon" "core" {
  for_each = toset(concat(
    ["vpc-cni", "coredns", "kube-proxy", "aws-ebs-csi-driver"],
    # The Pod Identity agent is a DaemonSet that hands the pod its credentials.
    # WITHOUT IT, a Pod Identity association exists in AWS and does nothing at
    # all, and Tempo reports a plain AccessDenied against S3.
    var.use_pod_identity ? ["eks-pod-identity-agent"] : [],
  ))

  cluster_name                = aws_eks_cluster.lgtm.name
  addon_name                  = each.value
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.lgtm]
}
