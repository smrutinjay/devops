output "bucket_name" {
  value       = aws_s3_bucket.tf_state.bucket
  description = "Paste this into terraform/backend.tf as the `bucket` value"
}

output "dynamodb_table_name" {
  value       = aws_dynamodb_table.tf_lock.name
  description = "Paste this into terraform/backend.tf as the `dynamodb_table` value"
}
