# Bucket for files uploaded through the app.
# Bucket names are global across all AWS accounts, so the account ID is
# appended to make the name unique without a random suffix.
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.project_name}-uploads-${data.aws_caller_identity.current.account_id}"

  # Course project: allow `terraform destroy` to delete a non-empty bucket.
  # In production you would leave this false to protect data.
  force_destroy = true
}

# The bucket is private: the app reaches it with IAM credentials, never publicly.
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
