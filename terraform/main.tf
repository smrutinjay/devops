##############################################################################
# NimbusCart — Three-Tier Infrastructure on AWS
#
# VPC-A (app-vpc)  10.0.0.0/16  -> public web subnet + private app subnet
# VPC-B (data-vpc) 10.1.0.0/16  -> isolated DB subnets (2 AZs, no IGW/NAT)
# Peering connects the two VPCs so the app tier can reach RDS.
##############################################################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

##############################################################################
# VPC-A: app-vpc (web tier + app tier)
##############################################################################

resource "aws_vpc" "app_vpc" {
  cidr_block           = var.app_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-app-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.app_vpc.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "web_public" {
  vpc_id                  = aws_vpc.app_vpc.id
  cidr_block              = var.web_subnet_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = true
  tags = { Name = "${var.project}-web-public-subnet" }
}

resource "aws_subnet" "app_private" {
  vpc_id            = aws_vpc.app_vpc.id
  cidr_block        = var.app_subnet_cidr
  availability_zone = var.az_a
  tags = { Name = "${var.project}-app-private-subnet" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.web_public.id
  tags          = { Name = "${var.project}-nat-gw" }
  depends_on    = [aws_internet_gateway.igw]
}

# Public route table -> web subnet
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "web_public_assoc" {
  subnet_id      = aws_subnet.web_public.id
  route_table_id = aws_route_table.public_rt.id
}

# Private route table -> app subnet (outbound via NAT, plus a peering
# route to data-vpc added below once the peering connection exists)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.app_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "app_private_assoc" {
  subnet_id      = aws_subnet.app_private.id
  route_table_id = aws_route_table.private_rt.id
}

##############################################################################
# VPC-B: data-vpc (isolated RDS subnets, no IGW, no NAT)
##############################################################################

resource "aws_vpc" "data_vpc" {
  cidr_block           = var.data_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project}-data-vpc" }
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.data_vpc.id
  cidr_block        = var.db_subnet_a_cidr
  availability_zone = var.az_a
  tags = { Name = "${var.project}-db-subnet-a" }
}

resource "aws_subnet" "db_b" {
  vpc_id            = aws_vpc.data_vpc.id
  cidr_block        = var.db_subnet_b_cidr
  availability_zone = var.az_b
  tags = { Name = "${var.project}-db-subnet-b" }
}

# Route table for data-vpc: NO route to an IGW or NAT. Only the peering
# route back to app-vpc is added below. This subnet cannot originate
# internet-bound traffic - see REPORT.md Task A, Q2.
resource "aws_route_table" "data_rt" {
  vpc_id = aws_vpc.data_vpc.id
  tags   = { Name = "${var.project}-data-rt" }
}

resource "aws_route_table_association" "db_a_assoc" {
  subnet_id      = aws_subnet.db_a.id
  route_table_id = aws_route_table.data_rt.id
}

resource "aws_route_table_association" "db_b_assoc" {
  subnet_id      = aws_subnet.db_b.id
  route_table_id = aws_route_table.data_rt.id
}

##############################################################################
# VPC Peering: app-vpc <-> data-vpc, with routes in BOTH directions
##############################################################################

resource "aws_vpc_peering_connection" "app_to_data" {
  vpc_id      = aws_vpc.app_vpc.id
  peer_vpc_id = aws_vpc.data_vpc.id
  auto_accept = true
  tags = { Name = "${var.project}-app-to-data-peering" }
}

# Forward route: app tier's private route table -> data-vpc CIDR via peering
resource "aws_route" "private_to_data" {
  route_table_id            = aws_route_table.private_rt.id
  destination_cidr_block    = var.data_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_data.id
}

# Return route: data-vpc's route table -> app-vpc CIDR via peering.
# Forget this one and the DB can send response packets nowhere - see
# REPORT.md Task A, Q1 for the demonstrated failure mode.
resource "aws_route" "data_to_app" {
  route_table_id            = aws_route_table.data_rt.id
  destination_cidr_block    = var.app_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_data.id
}

##############################################################################
# Security Groups
##############################################################################

resource "aws_security_group" "web_sg" {
  name        = "${var.project}-web-sg"
  description = "Web tier: HTTP/HTTPS from the internet"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH for provisioning"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-web-sg" }
}

resource "aws_security_group" "app_sg" {
  name        = "${var.project}-app-sg"
  description = "App tier: only reachable from the web tier on the app port"
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description     = "App port from web tier only"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  ingress {
    description = "SSH for provisioning (from within app-vpc only)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.app_vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-app-sg" }
}

resource "aws_security_group" "db_sg" {
  name        = "${var.project}-db-sg"
  description = "DB: only reachable from the app tier on the DB port"
  vpc_id      = aws_vpc.data_vpc.id

  ingress {
    description     = "DB port from app tier only"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }

  # Cross-VPC security group references (source = app_sg) only work
  # because these SGs live in peered VPCs; that's supported for peering
  # (unlike NACLs, which are CIDR-only - see REPORT.md Task C, Q4).

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-db-sg" }
}

##############################################################################
# ECR + image build/push (local-exec — see REPORT.md Task C, Q5)
##############################################################################

resource "aws_ecr_repository" "api" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  tags = { Name = "${var.project}-api-repo" }
}

resource "null_resource" "build_and_push_image" {
  # Rebuild/push whenever the app source changes.
  triggers = {
    dockerfile_hash = filesha256("${path.module}/../app/api/Dockerfile")
    app_hash        = filesha256("${path.module}/../app/api/app.py")
    reqs_hash       = filesha256("${path.module}/../app/api/requirements.txt")
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../app/api"
    command     = <<-EOT
      set -e
      aws ecr get-login-password --region ${var.region} | \
        docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com
      docker build -t ${aws_ecr_repository.api.repository_url}:${var.image_tag} .
      docker push ${aws_ecr_repository.api.repository_url}:${var.image_tag}
    EOT
  }

  depends_on = [aws_ecr_repository.api]
}

##############################################################################
# IAM: app tier instance profile — lets the app EC2 instance authenticate
# to ECR without any static credentials baked into user_data
##############################################################################

resource "aws_iam_role" "app_instance_role" {
  name = "${var.project}-app-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role       = aws_iam_role.app_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "app_instance_profile" {
  name = "${var.project}-app-instance-profile"
  role = aws_iam_role.app_instance_role.name
}

##############################################################################
# RDS: single products table, isolated data-vpc, subnet group across 2 AZs
##############################################################################

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "${var.project}-db-subnet-group"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_b.id]
  tags       = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_db_instance" "db" {
  identifier             = "${var.project}-db"
  engine                 = var.db_engine
  engine_version         = var.db_engine_version
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  port                    = var.db_port
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  publicly_accessible     = false
  multi_az                = false
  skip_final_snapshot     = true
  deletion_protection     = false

  # Schema is created by the API on first boot, not by Terraform or a
  # human with psql - see REPORT.md / assignment constraint.
}

##############################################################################
# EC2: App tier — private subnet, runs the API container
##############################################################################

resource "aws_instance" "app_tier" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.app_private.id
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.app_instance_profile.name

  tags = { Name = "${var.project}-app-tier" }

  # The app subnet has no public IP, so Terraform reaches it for
  # provisioning by hopping through the web tier's public IP.
  connection {
    type                = "ssh"
    user                = "ec2-user"
    private_key         = file(var.ssh_private_key_path)
    host                = self.private_ip
    bastion_host        = aws_instance.web_tier.public_ip
    bastion_user        = "ec2-user"
    bastion_private_key = file(var.ssh_private_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/app_setup.sh.tpl", {
      region      = var.region
      account_id  = data.aws_caller_identity.current.account_id
      image_uri   = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
      app_port    = var.app_port
      db_host     = aws_db_instance.db.address
      db_port     = var.db_port
      db_name     = var.db_name
      db_user     = var.db_username
      db_password = var.db_password
    })
    destination = "/tmp/app_setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/app_setup.sh",
      "/tmp/app_setup.sh",
    ]
  }

  depends_on = [
    null_resource.build_and_push_image,
    aws_db_instance.db,
    aws_route.private_to_data,
    aws_route.data_to_app,
  ]
}

##############################################################################
# EC2: Web tier — public subnet, runs nginx (static frontend + /api proxy)
##############################################################################

resource "aws_instance" "web_tier" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.web_public.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  tags = { Name = "${var.project}-web-tier" }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
    host        = self.public_ip
  }

  # NOTE: this instance intentionally does NOT reference aws_instance.app_tier
  # anywhere. app_tier's own connection block uses this instance as an SSH
  # bastion (aws_instance.web_tier.public_ip), so if web_tier also referenced
  # app_tier's private_ip, Terraform would see a dependency cycle between the
  # two instances. Instead, the nginx reverse-proxy config (which does need
  # app_tier's private IP) is applied afterwards by the standalone
  # null_resource.configure_web_proxy below, once both instances exist.

  provisioner "file" {
    source      = "${path.module}/../app/frontend/index.html"
    destination = "/tmp/index.html"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo dnf install -y nginx",
      "sudo systemctl enable nginx",
      "sudo mkdir -p /usr/share/nginx/html",
      "sudo cp /tmp/index.html /usr/share/nginx/html/index.html",
      "sudo rm -f /etc/nginx/conf.d/default.conf || true",
      "sudo systemctl restart nginx",
    ]
  }
}

##############################################################################
# Web tier, phase 2 — apply the /api/ reverse-proxy config once the app
# tier's private IP is known. Kept as a separate resource specifically to
# avoid the web_tier <-> app_tier dependency cycle described above.
##############################################################################

resource "null_resource" "configure_web_proxy" {
  triggers = {
    app_private_ip = aws_instance.app_tier.private_ip
    web_instance_id = aws_instance.web_tier.id
  }

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file(var.ssh_private_key_path)
    host        = aws_instance.web_tier.public_ip
  }

  provisioner "file" {
    content = templatefile("${path.module}/nginx.conf.tpl", {
      app_private_ip = aws_instance.app_tier.private_ip
      app_port       = var.app_port
    })
    destination = "/tmp/nimbuscart.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /tmp/nimbuscart.conf /etc/nginx/conf.d/nimbuscart.conf",
      "sudo nginx -t",
      "sudo systemctl restart nginx",
    ]
  }

  depends_on = [aws_instance.web_tier, aws_instance.app_tier]
}
