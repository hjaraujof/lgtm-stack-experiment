output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.lgtm.name
}

output "kubeconfig_command" {
  description = "Point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.lgtm.name}"
}

output "lgtm_role_arn" {
  description = "The role Tempo, Mimir and the Secrets Store CSI driver assume. On the IRSA path, annotate the chart's ServiceAccount with it. On the Pod Identity path it is informational: the association below has already bound it, and the chart needs no annotation."
  value       = aws_iam_role.telemetry.arn
}

output "identity_mechanism" {
  description = "Which mechanism this apply configured. Both are credential-less."
  value       = var.use_pod_identity ? "EKS Pod Identity" : "IRSA"
}

output "service_account_binding" {
  description = "The exact ServiceAccount the role is bound to. IT MUST MATCH THE CHART. The chart names its account <release>-lgtm, so `helm install lgtm ...` yields lgtm-lgtm. A mismatch does not fail this apply - the pods simply receive no AWS identity, and the first symptom is an AccessDenied from S3 minutes later."
  value       = "${var.service_account_namespace}/${var.service_account_name}"
}

output "traces_bucket" {
  description = "Set as tempo.configOverride.storage.trace.s3.bucket in values-eks.yaml."
  value       = aws_s3_bucket.traces.bucket
}

output "metrics_bucket" {
  description = "Set as mimir.configOverride...bucket_name in values-eks.yaml, in BOTH places (common.storage and alertmanager_storage)."
  value       = aws_s3_bucket.metrics.bucket
}

output "next_steps" {
  description = "What to run after this apply."
  value       = <<-EOT
    1. aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.lgtm.name}

    2. Install the controllers this chart needs and cannot install:
         ingress-nginx, cert-manager, the Secrets Store CSI driver and its AWS provider.

    3. Copy the two bucket names above into
       k8s/charts/lgtm-stack/values-eks.yaml.
    ${var.use_pod_identity ? "" : "   Also add this annotation under serviceAccount.annotations:\n         eks.amazonaws.com/role-arn: ${aws_iam_role.telemetry.arn}"}
    4. helm upgrade --install lgtm k8s/charts/lgtm-stack \
         -n ${var.service_account_namespace} --create-namespace \
         -f k8s/charts/lgtm-stack/values-eks.yaml

    5. helm test lgtm -n ${var.service_account_namespace}
  EOT
}
