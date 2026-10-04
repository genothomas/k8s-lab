locals {
  node_names = ["node-01", "node-02", "node-03"]

  # user_data runs NAT-free (hostname only). MASQUERADE + FORWARD rules
  # are owned by ansible/roles/common — runs after cloud-init finishes,
  # no race against unattended-upgrades/apt locks.
  edge_user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    hostnamectl set-hostname edge-01
    sed -i 's/^127.0.1.1.*/127.0.1.1 edge-01/' /etc/hosts
  EOF
}

resource "aws_key_pair" "edge" {
  key_name   = "${var.cluster_name}-${var.environment}-edge"
  public_key = file(var.edge_public_key_path)
}

resource "aws_key_pair" "nodes" {
  key_name   = "${var.cluster_name}-${var.environment}-nodes"
  public_key = file(var.nodes_public_key_path)
}

resource "aws_instance" "edge" {
  ami                    = var.ami_id
  instance_type          = var.edge_instance_type
  subnet_id              = values(var.public_subnet_ids)[0]
  vpc_security_group_ids = [var.edge_sg_id]
  key_name               = aws_key_pair.edge.key_name

  associate_public_ip_address = true
  source_dest_check           = var.edge_enable_nat ? false : true

  metadata_options {
    http_tokens = "required"
  }

  user_data = local.edge_user_data

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.cluster_name}-${var.environment}-edge-01"
    Role = var.edge_enable_nat ? "edge+nat" : "edge"
  }
}

resource "aws_eip" "edge" {
  count    = var.enable_elastic_ip ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.edge.id

  tags = {
    Name = "${var.cluster_name}-${var.environment}-edge-eip"
  }
}

resource "aws_instance" "nodes" {
  for_each = {
    for i, az in var.availability_zones :
    local.node_names[i] => {
      subnet_id = var.private_subnet_ids[az]
    }
  }

  ami                    = var.ami_id
  instance_type          = var.node_instance_type
  subnet_id              = each.value.subnet_id
  vpc_security_group_ids = [var.nodes_sg_id]
  key_name               = aws_key_pair.nodes.key_name

  associate_public_ip_address = false
  source_dest_check           = false

  metadata_options {
    http_tokens = "required"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    hostnamectl set-hostname ${each.key}
    sed -i 's/^127.0.1.1.*/127.0.1.1 ${each.key}/' /etc/hosts
  EOF

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.cluster_name}-${var.environment}-${each.key}"
    Role = "control-plane+worker"
  }
}