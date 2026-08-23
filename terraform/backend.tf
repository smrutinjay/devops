# Remote state for the MAIN nimbuscart infrastructure.
#
# `bucket` and `dynamodb_table` come from the outputs of
# terraform/backend-bootstrap (run that config first, once, then fill
# these in - see REPORT.md Task C, Q6 for why this can't be one config).

terraform {
  backend "s3" {
    bucket         = "nimbuscart-tf-state-REPLACE_ME"   # from backend-bootstrap output: bucket_name
    key            = "nimbuscart/terraform.tfstate"
    region         = "us-east-1"                        # must match backend-bootstrap `region` var
    dynamodb_table = "nimbuscart-tf-lock"                # from backend-bootstrap output: dynamodb_table_name
    encrypt        = true
  }
}
