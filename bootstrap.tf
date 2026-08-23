# =============================================================================
# Bootstrap bucket — the instance fetches the stack archive from here at boot
# =============================================================================
# This replaces the SSH-deploy-key + git-clone boot path.
#
# WHY. The git-clone path needs a private key on the box. Terraform has to get
# that key to the instance, which means either templating it into user_data
# (readable through IMDS and stored in the state file) or fetching it from
# Secrets Manager and writing it to disk. Both leave durable key material on a
# host whose whole job is to accept telemetry from the network.
#
# Instead, CI publishes a tarball of the repo here, and the instance pulls it
# using its own IAM role over the free same-VPC S3 gateway endpoint. No git
# credential exists on the box at all, so none can leak from it. Integrity is
# verified fail-closed with a sha256 before extraction — see user_data.tpl.
#
# The publishing role is NOT defined here. It is a GitHub OIDC role with write
# access to exactly these two objects, created out of band; see
# docs/runbooks/bootstrap-publish-role.md. Keeping it out of this configuration
# means the stack's own Terraform never needs permission to grant write access
# to its own boot source.

resource "aws_s3_bucket" "lgtm_bootstrap" {
  bucket = "lgtm-bootstrap-${local.s3_region}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "lgtm-bootstrap", Component = "boot-archive", ManagedBy = "terraform" }
}

resource "aws_s3_bucket_public_access_block" "lgtm_bootstrap" {
  bucket                  = aws_s3_bucket.lgtm_bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning ON so a bad publish is recoverable: roll back to a prior object
# version rather than re-running CI against a reverted commit.
resource "aws_s3_bucket_versioning" "lgtm_bootstrap" {
  bucket = aws_s3_bucket.lgtm_bootstrap.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lgtm_bootstrap" {
  bucket = aws_s3_bucket.lgtm_bootstrap.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Expire noncurrent versions so the recovery window does not grow without bound,
# and abort stale multipart uploads. A failed multipart upload is invisible to
# the expiration rule and bills forever.
resource "aws_s3_bucket_lifecycle_configuration" "lgtm_bootstrap" {
  bucket = aws_s3_bucket.lgtm_bootstrap.id
  rule {
    id     = "expire-noncurrent-bootstrap"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# The instance gets READ-ONLY GetObject on the two bootstrap objects only. Not
# the whole bucket, and no list, put or delete. A compromised box can read the
# archive it already booted from and nothing else.
#
# GetObjectVersion is included so a boot can pin a specific version during a
# rollback.
resource "aws_iam_role_policy" "lgtm_bootstrap_read" {
  name = "lgtm-bootstrap-read"
  role = aws_iam_role.lgtm_instance_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadBootstrapArchive"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = [
          "${aws_s3_bucket.lgtm_bootstrap.arn}/lgtm_stack.tar.gz",
          "${aws_s3_bucket.lgtm_bootstrap.arn}/lgtm_stack.sha256",
        ]
      }
    ]
  })
}

output "lgtm_bootstrap_bucket" {
  value       = aws_s3_bucket.lgtm_bootstrap.bucket
  description = "S3 bucket the EC2 instance pulls the stack archive from at boot (published by CI)"
}
