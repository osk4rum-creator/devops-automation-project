# Identity for the LOCAL (k3d) cluster only. A laptop cluster can't use IRSA,
# so the backend and worker use this user's access key, stored as a
# Kubernetes Secret. On EKS this is replaced by IRSA roles (no static keys).
#
# The access key is deliberately NOT created here: Terraform would store the
# secret in terraform.tfstate. Create it with the AWS CLI instead (see README).
resource "aws_iam_user" "app_local" {
  name = "${var.project_name}-local"
}

# Least privilege: only the two actions the app needs, on these exact resources.
data "aws_iam_policy_document" "app_local" {
  statement {
    sid       = "UploadFiles"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.uploads.arn}/uploads/*"]
  }

  statement {
    sid       = "SendNotifications"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.uploads.arn]
  }
}

resource "aws_iam_user_policy" "app_local" {
  name   = "${var.project_name}-local-app"
  user   = aws_iam_user.app_local.name
  policy = data.aws_iam_policy_document.app_local.json
}
