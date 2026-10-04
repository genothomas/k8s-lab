resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-${var.environment}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-${var.environment}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = {
    for i, az in var.availability_zones :
    az => {
      cidr = var.public_subnet_cidrs[i]
    }
  }

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value.cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-${var.environment}-public-${each.key}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  for_each = {
    for i, az in var.availability_zones :
    az => {
      cidr = var.private_subnet_cidrs[i]
    }
  }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value.cidr

  tags = {
    Name = "${var.cluster_name}-${var.environment}-private-${each.key}"
    Tier = "private"
  }
}

locals {
  create_nat = !var.edge_enable_nat
}

resource "aws_eip" "nat" {
  count  = local.create_nat ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-${var.environment}-nat-eip"
  }
}

resource "aws_security_group" "nat" {
  count       = local.create_nat ? 1 : 0
  name        = "${var.cluster_name}-${var.environment}-nat"
  description = "NAT instance: SSH from admin CIDRs for management; egress all."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.cluster_name}-${var.environment}-nat"
  }
}

resource "aws_security_group_rule" "nat_ssh" {
  count             = local.create_nat ? 1 : 0
  type              = "ingress"
  description       = "SSH from admin CIDRs"
  security_group_id = aws_security_group.nat[0].id

  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.ssh_admin_cidrs
}

resource "aws_security_group_rule" "nat_egress_all" {
  count             = local.create_nat ? 1 : 0
  type              = "egress"
  description       = "NAT egress: all (forwarded traffic from private subnets)"
  security_group_id = aws_security_group.nat[0].id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_instance" "nat" {
  count = local.create_nat ? 1 : 0

  ami                    = var.nat_ami_id
  instance_type          = var.nat_instance_type
  subnet_id              = aws_subnet.public[var.availability_zones[0]].id
  vpc_security_group_ids = [aws_security_group.nat[0].id]
  key_name               = var.nat_ssh_key_name

  associate_public_ip_address = true
  source_dest_check           = false

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-nat.conf
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -yqq iptables-persistent
    iptables -t nat -A POSTROUTING -s ${var.vpc_cidr} ! -d ${var.vpc_cidr} -j MASQUERADE
    netfilter-persistent save
  EOF

  root_block_device {
    volume_size           = var.nat_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.cluster_name}-${var.environment}-nat"
    Role = "nat"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_eip_association" "nat" {
  count         = local.create_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  instance_id   = aws_instance.nat[0].id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.cluster_name}-${var.environment}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = var.edge_enable_nat ? var.nat_eni_id : aws_instance.nat[0].primary_network_interface_id
  }

  tags = {
    Name = "${var.cluster_name}-${var.environment}-private-rt"
  }

  depends_on = [aws_eip_association.nat]
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}