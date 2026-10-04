resource "aws_security_group" "edge_bastion" {
  name        = "${var.cluster_name}-${var.environment}-edge-bastion"
  description = "Edge/bastion: HAProxy fronts kube API and HTTP(S); bastion for SSH ProxyJump."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-${var.environment}-edge-bastion"
  }
}

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-${var.environment}-nodes"
  description = "Kubernetes control-plane+worker nodes. Self-references for CNI/etcd/kubelet."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.cluster_name}-${var.environment}-nodes"
  }
}

# --- edge-bastion ingress ---

resource "aws_security_group_rule" "edge_ssh" {
  type              = "ingress"
  description       = "SSH from admin CIDRs"
  security_group_id = aws_security_group.edge_bastion.id

  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.ssh_admin_cidrs
}

resource "aws_security_group_rule" "edge_api" {
  type              = "ingress"
  description       = "Kubernetes API (TCP 6443) via HAProxy front"
  security_group_id = aws_security_group.edge_bastion.id

  from_port   = 6443
  to_port     = 6443
  protocol    = "tcp"
  cidr_blocks = var.kubernetes_api_allowed_cidrs
}

resource "aws_security_group_rule" "edge_http" {
  type              = "ingress"
  description       = "HTTP (TCP 80) via HAProxy front"
  security_group_id = aws_security_group.edge_bastion.id

  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = var.http_allowed_cidrs
}

resource "aws_security_group_rule" "edge_https" {
  type              = "ingress"
  description       = "HTTPS (TCP 443) via HAProxy front"
  security_group_id = aws_security_group.edge_bastion.id

  from_port   = 443
  to_port     = 443
  protocol    = "tcp"
  cidr_blocks = var.http_allowed_cidrs
}

resource "aws_security_group_rule" "edge_egress_all" {
  type              = "egress"
  description       = "Edge egress: all (apt, curl, GH CLI)"
  security_group_id = aws_security_group.edge_bastion.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

# Edge SNATs node/pod traffic via iptables MASQUERADE. AWS treats the
# MASQUERADE'd SYN as a fresh egress from edge-01, but stateful SG tracking
# sometimes misses the cross-iptables rewrite and drops the reply on the
# high (ephemeral) port edge-01 chose. Permit the Linux default ephemeral
# range explicitly so DNS / arbitrary UDP/TCP replies always reach the
# kernel regardless of SG state-tracking behaviour. TCP+UDP only — ICMP
# has no MASQUERADE use case here. Source is 0.0.0.0/0 because replies
# arrive from arbitrary public IPs (1.1.1.1, 8.8.8.8, …), not the VPC CIDR.
resource "aws_security_group_rule" "edge_ingress_ephemeral" {
  type              = "ingress"
  description       = "Edge ingress: ephemeral ports for MASQUERADE return traffic (TCP+UDP)"
  security_group_id = aws_security_group.edge_bastion.id

  from_port   = 32768
  to_port     = 60999
  protocol    = "-1"
  cidr_blocks = [var.vpc_cidr]
}

# --- nodes ingress ---

resource "aws_security_group_rule" "nodes_ssh_from_edge" {
  type                     = "ingress"
  description              = "SSH from edge bastion (ProxyJump)"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.edge_bastion.id

  from_port = 22
  to_port   = 22
  protocol  = "tcp"
}

resource "aws_security_group_rule" "nodes_api_from_edge" {
  type                     = "ingress"
  description              = "Kubernetes API (TCP 6443) from HAProxy front"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.edge_bastion.id

  from_port = 6443
  to_port   = 6443
  protocol  = "tcp"
}

resource "aws_security_group_rule" "nodes_http_from_edge" {
  type                     = "ingress"
  description              = "HTTP (TCP 80) from HAProxy front to Cilium Gateway"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.edge_bastion.id

  from_port = 80
  to_port   = 80
  protocol  = "tcp"
}

resource "aws_security_group_rule" "nodes_https_from_edge" {
  type                     = "ingress"
  description              = "HTTPS (TCP 443) from HAProxy front to Cilium Gateway"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.edge_bastion.id

  from_port = 443
  to_port   = 443
  protocol  = "tcp"
}

resource "aws_security_group_rule" "nodes_self" {
  type                     = "ingress"
  description              = "All traffic from peer nodes (CNI, etcd, kubelet, kube-proxy)"
  security_group_id        = aws_security_group.nodes.id
  source_security_group_id = aws_security_group.nodes.id

  from_port = 0
  to_port   = 0
  protocol  = "-1"
}

resource "aws_security_group_rule" "nodes_egress_all" {
  type              = "egress"
  description       = "Nodes egress: all (image pulls, apt)"
  security_group_id = aws_security_group.nodes.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}