############################################
# Secure VPC lab: public bastion + private host
# No NAT Gateway (costs money), no load balancer.
############################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "my_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR form, e.g. 203.0.113.10/32 (get it with: curl ifconfig.me)"
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "instance_type" {
  type        = string
  default     = "t3.micro"
  description = "Check which type is free-tier eligible in your region/account"
}

provider "aws" {
  region = var.region
}

locals {
  tags = { Project = "secure-vpc-lab" }
}

# ---------- Network ----------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "lab-vpc" })
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "lab-public" })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = merge(local.tags, { Name = "lab-private" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "lab-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.tags, { Name = "lab-public-rt" })
}

# Private route table: local routes only, no internet path
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "lab-private-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------- Security groups (stateful) ----------
resource "aws_security_group" "bastion" {
  name        = "lab-bastion-sg"
  description = "SSH from my IP only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "lab-bastion-sg" })
}

resource "aws_security_group" "private" {
  name        = "lab-private-sg"
  description = "SSH from bastion only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from bastion SG"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }

  tags = merge(local.tags, { Name = "lab-private-sg" })
}

# ---------- NACLs (stateless, so ephemeral return ports are needed) ----------
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public.id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = var.my_ip_cidr
    from_port  = 22
    to_port    = 22
  }
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = merge(local.tags, { Name = "lab-public-nacl" })
}

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.private.id]

  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_subnet.public.cidr_block
    from_port  = 22
    to_port    = 22
  }
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    cidr_block = aws_subnet.public.cidr_block
    from_port  = 1024
    to_port    = 65535
  }

  tags = merge(local.tags, { Name = "lab-private-nacl" })
}

# ---------- Compute ----------
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "lab" {
  key_name   = "lab-key"
  public_key = file(pathexpand(var.public_key_path))
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = aws_key_pair.lab.key_name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }
  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "lab-bastion" })
}

resource "aws_instance" "private" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.private.id]
  key_name               = aws_key_pair.lab.key_name

  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    volume_size = 8
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "lab-private" })
}

# ---------- Outputs ----------
output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "private_ip" {
  value = aws_instance.private.private_ip
}

output "ssh_to_private" {
  value = "ssh -J ubuntu@${aws_instance.bastion.public_ip} ubuntu@${aws_instance.private.private_ip}"
}
