data "aws_ami" "ubuntu_24_04" {
  count = var.ami_id_override == null ? 1 : 0

  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id_override != null ? var.ami_id_override : data.aws_ami.ubuntu_24_04[0].id

  common_tags = {
    Cluster     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = "k8s-lab"
  }
}