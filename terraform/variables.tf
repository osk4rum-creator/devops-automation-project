variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Prefix for resource names and the Project tag"
  type        = string
  default     = "devops-app"
}

variable "alert_email" {
  description = "Email address that receives SNS notifications (must confirm the subscription email)"
  type        = string
}
