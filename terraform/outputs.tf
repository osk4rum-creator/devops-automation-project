# These values go into the Helm chart's ConfigMap (they are not secrets).
output "s3_bucket_name" {
  value = aws_s3_bucket.uploads.bucket
}

output "sns_topic_arn" {
  value = aws_sns_topic.uploads.arn
}

output "aws_region" {
  value = var.aws_region
}

output "local_app_iam_user" {
  description = "Create its access key with: aws iam create-access-key --user-name <this>"
  value       = aws_iam_user.app_local.name
}
