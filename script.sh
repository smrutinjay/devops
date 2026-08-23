#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/terraform"

terraform init
terraform plan
terraform apply -auto-approve
