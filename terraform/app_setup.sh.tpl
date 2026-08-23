#!/bin/bash
set -euxo pipefail

# --- Install Docker -----------------------------------------------------
sudo dnf install -y docker
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user

# --- Authenticate to ECR --------------------------------------------------
# No static credentials here: this instance carries an IAM instance
# profile (AmazonEC2ContainerRegistryReadOnly), and it reaches ECR's
# public endpoint through the shared NAT Gateway in the public subnet
# (this instance has no public IP and no NAT of its own).
# See REPORT.md Task C, Q3 for the full walk-through.
sudo aws ecr get-login-password --region ${region} | \
  sudo docker login --username AWS --password-stdin ${account_id}.dkr.ecr.${region}.amazonaws.com

# --- Pull and run the API container --------------------------------------
sudo docker pull ${image_uri}

sudo docker rm -f nimbuscart-api || true

sudo docker run -d \
  --name nimbuscart-api \
  --restart unless-stopped \
  -p ${app_port}:${app_port} \
  -e DB_HOST=${db_host} \
  -e DB_PORT=${db_port} \
  -e DB_NAME=${db_name} \
  -e DB_USER=${db_user} \
  -e DB_PASSWORD=${db_password} \
  -e PORT=${app_port} \
  ${image_uri}
