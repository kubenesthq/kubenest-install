terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  default = "ap-south-1"
}

variable "instance_type" {
  default = "t3.medium"
}

variable "disk_size_gb" {
  default = 30
}

variable "name" {
  default = "kubenest-cp"
}

# --- SSH Key ---

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "cp" {
  key_name   = "${var.name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/cp_key"
  file_permission = "0600"
}

# --- Security Group ---

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "cp" {
  name        = "${var.name}-sg"
  description = "KubeNest control plane"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- EC2 Instance ---

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_instance" "cp" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.cp.key_name
  vpc_security_group_ids      = [aws_security_group.cp.id]
  subnet_id                   = data.aws_subnets.default.ids[0]
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
  }

  tags = {
    Name = var.name
  }
}

# --- Outputs ---

output "public_ip" {
  value = aws_instance.cp.public_ip
}

output "ssh_command" {
  value = "ssh -i ${path.module}/cp_key ubuntu@${aws_instance.cp.public_ip}"
}

output "install_command" {
  value = "curl -sSL https://raw.githubusercontent.com/kubenesthq/kubenest-install/main/install.sh | sudo bash -s -- --domain <YOUR_DOMAIN> --admin-email <YOUR_EMAIL>"
}
