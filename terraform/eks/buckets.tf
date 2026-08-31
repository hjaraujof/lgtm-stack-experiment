# =============================================================================
# Object storage for the Kubernetes plane
# =============================================================================
# NEW BUCKETS, NOT THE ONES IN s3-backends.tf. READ THIS BEFORE YOU "SAVE" TWO
# BUCKETS BY SHARING THEM.
#
# Mimir refuses to start when two of its own stores share a bucket AND a prefix.
# It does NOT refuse when two SEPARATE Mimir instances share one - it cannot see
# the other instance. Both then upload blocks and both run a compactor over the
# same objects. The result is not an error; it is silently corrupted block
# metadata and lost metrics. The same applies to Tempo.
#
# Two planes therefore get two sets of buckets. That is not duplication, it is
# isolation.

resource "aws_s3_bucket" "traces" {
  bucket = "lgtm-eks-traces-${var.region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-eks-traces", Component = "Tempo" }
}

resource "aws_s3_bucket" "metrics" {
  bucket = "lgtm-eks-metrics-${var.region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-eks-metrics", Component = "Mimir" }
}

resource "aws_s3_bucket_public_access_block" "traces" {
  bucket                  = aws_s3_bucket.traces.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "metrics" {
  bucket                  = aws_s3_bucket.metrics.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "traces" {
  bucket = aws_s3_bucket.traces.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "metrics" {
  bucket = aws_s3_bucket.metrics.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# LIFECYCLE EXPIRATION IS A COMPACTOR-STALL BACKSTOP, not the retention policy.
# The real retention lives in the backends' own configs. This catches the case
# where a compactor stops deleting and nobody notices for a month.
#
# NO VERSIONING. Expiration on a versioned bucket only writes delete markers and
# leaves every byte in place, so the backstop would silently stop working.
resource "aws_s3_bucket_lifecycle_configuration" "traces" {
  bucket = aws_s3_bucket.traces.id
  rule {
    id     = "expire-traces"
    status = "Enabled"
    filter {}
    expiration { days = var.trace_retention_days }
    # An upload that fails mid-way leaves parts that are billed and invisible in
    # a normal listing. Compaction uploads are large and multipart, so this is
    # not hypothetical here.
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "metrics" {
  bucket = aws_s3_bucket.metrics.id
  rule {
    id     = "expire-metrics"
    status = "Enabled"
    filter {}
    expiration { days = var.metric_retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}
