variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a naming/tag prefix"
  type        = string
  default     = "nimbuscart"
}

# --- Networking -------------------------------------------------------

variable "app_vpc_cidr" {
  description = "CIDR for VPC-A (app-vpc): web tier + app tier"
  type        = string
  default     = "10.0.0.0/16"
}

variable "web_subnet_cidr" {
  description = "Public subnet CIDR for the web tier"
  type        = string
  default     = "10.0.1.0/24"
}

variable "app_subnet_cidr" {
  description = "Private subnet CIDR for the app tier"
  type        = string
  default     = "10.0.2.0/24"
}

variable "data_vpc_cidr" {
  description = "CIDR for VPC-B (data-vpc): isolated RDS subnets"
  type        = string
  default     = "10.1.0.0/16"
}

variable "db_subnet_a_cidr" {
  description = "First isolated DB subnet CIDR (AZ-a)"
  type        = string
  default     = "10.1.1.0/24"
}

variable "db_subnet_b_cidr" {
  description = "Second isolated DB subnet CIDR (AZ-b) - RDS subnet groups need 2+ AZs"
  type        = string
  default     = "10.1.2.0/24"
}

variable "az_a" {
  description = "First availability zone"
  type        = string
  default     = "us-east-1a"
}

variable "az_b" {
  description = "Second availability zone"
  type        = string
  default     = "us-east-1b"
}

# --- Compute ------------------------------------------------------------

variable "ami_id" {
  description = "AMI for both EC2 instances (Amazon Linux 2023 recommended). Must be set for your region."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for web and app tier"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Existing EC2 key pair name, used for the remote-exec/file provisioner SSH connection"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the local private key file matching key_name, used by Terraform provisioners"
  type        = string
}

variable "app_port" {
  description = "Port the containerized API listens on"
  type        = number
  default     = 8080
}

# --- Database -------------------------------------------------------

variable "db_engine" {
  description = "postgres or mysql"
  type        = string
  default     = "postgres"
}

variable "db_engine_version" {
  description = "Engine version"
  type        = string
  default     = "16.3"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Database name the API connects to"
  type        = string
  default     = "nimbuscart"
}

variable "db_username" {
  description = "Master username for RDS"
  type        = string
  default     = "nimbuscart"
}

variable "db_password" {
  description = "Master password for RDS"
  type        = string
  sensitive   = true
}

variable "db_port" {
  description = "DB port (5432 for postgres, 3306 for mysql)"
  type        = number
  default     = 5432
}

# --- Container image --------------------------------------------------

variable "ecr_repo_name" {
  description = "Name of the ECR repository the API image is pushed to"
  type        = string
  default     = "nimbuscart-api"
}

variable "image_tag" {
  description = "Tag applied to the built API image"
  type        = string
  default     = "latest"
}
