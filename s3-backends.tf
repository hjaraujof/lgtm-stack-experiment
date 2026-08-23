# =============================================================================
# S3 Object Storage for Tempo (traces) + Mimir (metrics)
# =============================================================================
# Moves LGTM block storage off the single EBS root volume to S3, removing the
# disk-full failure mode. Free S3 Gateway VPC Endpoint (no NAT, same-region
# transfer is $0). Scoped IAM on the instance role. Mandatory lifecycle
# expiration as a compactor-stall backstop.
#
# Apply order (see plan): create this infra + pre-flight IAM (aws s3 cp) BEFORE
# flipping backends in tempo-config.yaml / mimir-config.yaml.

data "aws_caller_identity" "current" {}

locals {
  s3_region = "us-east-1"
}

resource "aws_s3_bucket" "lgtm_traces" {
  bucket = "lgtm-traces-${local.s3_region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-traces", Component = "Tempo", ManagedBy = "terraform" }
}

resource "aws_s3_bucket" "lgtm_metrics" {
  bucket = "lgtm-metrics-${local.s3_region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-metrics", Component = "Mimir", ManagedBy = "terraform" }
}

# Block all public access (defense-in-depth; these hold telemetry).
resource "aws_s3_bucket_public_access_block" "lgtm_traces" {
  bucket                  = aws_s3_bucket.lgtm_traces.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "lgtm_metrics" {
  bucket                  = aws_s3_bucket.lgtm_metrics.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle expiration = compactor-stall backstop. NO versioning (expiration on a
# versioned bucket only creates delete markers, leaving bytes). Windows exceed the
# backends' own retention (Tempo 72h block_retention, Mimir 336h tsdb) plus buffer.
resource "aws_s3_bucket_lifecycle_configuration" "lgtm_traces" {
  bucket = aws_s3_bucket.lgtm_traces.id
  rule {
    id     = "expire-traces"
    status = "Enabled"
    filter {}
    expiration { days = 5 } # > 72h block_retention + compaction window + buffer
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lgtm_metrics" {
  bucket = aws_s3_bucket.lgtm_metrics.id
  rule {
    id     = "expire-metrics"
    status = "Enabled"
    filter {}
    expiration { days = 16 } # > 336h (14d) tsdb retention + buffer
  }
}

# NOTE: An S3 Gateway VPC Endpoint ALREADY EXISTS in this shared VPC
# (vpce-0123456789abcdef0, associated with route table rtb-0123456789abcdef0 that
# our public subnet uses). EC2<->S3 traffic already routes through it for free.
# Creating another endpoint failed with RouteAlreadyExists, so we rely on the
# existing one — no aws_vpc_endpoint resource needed here.

# Scoped IAM: the instance role may read/write/delete ONLY these two buckets.
# DeleteObject is required for compaction. List for block discovery.
resource "aws_iam_role_policy" "lgtm_s3_access" {
  name = "lgtm-s3-backends"
  role = aws_iam_role.lgtm_instance_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TracesBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.lgtm_traces.arn, "${aws_s3_bucket.lgtm_traces.arn}/*"]
      },
      {
        Sid      = "MetricsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.lgtm_metrics.arn, "${aws_s3_bucket.lgtm_metrics.arn}/*"]
      }
    ]
  })
}

output "lgtm_traces_bucket" {
  value       = aws_s3_bucket.lgtm_traces.bucket
  description = "S3 bucket for Tempo trace blocks (set as tempo-config storage.trace.s3.bucket)"
}

output "lgtm_metrics_bucket" {
  value       = aws_s3_bucket.lgtm_metrics.bucket
  description = "S3 bucket for Mimir metric blocks (set as mimir-config blocks_storage.s3.bucket_name)"
}
