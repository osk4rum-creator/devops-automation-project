terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State is kept locally in this folder (terraform.tfstate, gitignored).
  # Rule: run Terraform ONLY from this folder and delete resources ONLY with
  # `terraform destroy` - otherwise state and AWS drift apart.
}

provider "aws" {
  region = var.aws_region

  # Every resource gets these tags, so you can always find (and audit) what
  # Terraform created: AWS Console -> Resource Groups -> Tag Editor.
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
