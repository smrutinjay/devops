# backend-bootstrap
#
# This is a SEPARATE Terraform configuration with its own (local) state.
# Its only job is to create the S3 bucket + DynamoDB table that the main
# `terraform/` configuration uses as its remote backend.
#
# Why separate? See REPORT.md Task C, Q6 - a config can't reference a
# backend that doesn't exist yet, so the backend's own infra has to be
# created outside of, and before, the state it will hold.
#
# Run this once, by hand, before running script.sh:
#   cd terraform/backend-bootstrap
#   terraform init
#   terraform apply -auto-approve
#
# Then copy the bucket_name / dynamodb_table_name outputs into
# terraform/backend.tf.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region for backend resources"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a naming prefix"
  type        = string
  default     = "nimbuscart"
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "${var.project}-tf-state-${random_id.suffix.hex}"

  # State files can contain sensitive data (DB endpoints, etc.) - never
  # let this bucket be destroyed by accident along with everything else.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "${var.project}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
