# Topic the worker publishes to whenever a new file is uploaded.
resource "aws_sns_topic" "uploads" {
  name = "${var.project_name}-uploads"
}

# Email subscription. AWS sends a confirmation email after `apply`;
# nothing is delivered until you click "Confirm subscription" in it.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.uploads.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
