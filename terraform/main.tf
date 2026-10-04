module "network" {
  source = "./network"

  cluster_name         = var.cluster_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones

  nat_eni_id              = local.edge_nat_eni_id
  edge_enable_nat         = var.edge_enable_nat
  nat_ami_id              = local.ami_id
  nat_instance_type       = var.nat_instance_type
  nat_ssh_public_key_path = var.edge_public_key_path
  nat_ssh_key_name        = "${var.cluster_name}-${var.environment}-edge"
  nat_root_volume_size    = var.root_volume_size
  ssh_admin_cidrs         = var.ssh_admin_cidrs
}

module "firewall" {
  source = "./firewall"

  cluster_name                 = var.cluster_name
  environment                  = var.environment
  vpc_id                       = module.network.vpc_id
  vpc_cidr                     = var.vpc_cidr
  ssh_admin_cidrs              = var.ssh_admin_cidrs
  kubernetes_api_allowed_cidrs = var.kubernetes_api_allowed_cidrs
  http_allowed_cidrs           = var.http_allowed_cidrs
}

module "vps" {
  source = "./vps"

  cluster_name          = var.cluster_name
  environment           = var.environment
  public_subnet_ids     = module.network.public_subnet_ids
  private_subnet_ids    = module.network.private_subnet_ids
  edge_sg_id            = module.firewall.edge_security_group_id
  nodes_sg_id           = module.firewall.nodes_security_group_id
  edge_public_key_path  = var.edge_public_key_path
  nodes_public_key_path = var.nodes_public_key_path
  edge_instance_type    = var.edge_instance_type
  node_instance_type    = var.node_instance_type
  root_volume_size      = var.root_volume_size
  ami_id                = local.ami_id
  enable_elastic_ip     = var.enable_elastic_ip
  availability_zones    = var.availability_zones
  edge_enable_nat       = var.edge_enable_nat
  vpc_cidr              = var.vpc_cidr
}

module "dns" {
  source = "./dns"

  count = var.enable_dns ? 1 : 0

  edge_public_ip = local.edge_public_ip
  dns_zone       = var.dns_zone
  dns_subdomain  = var.dns_subdomain
}

locals {
  edge_public_ip  = var.enable_elastic_ip ? module.vps.edge_eip : module.vps.edge_instance_public_ip
  edge_nat_eni_id = var.edge_enable_nat ? module.vps.edge_primary_network_interface_id : null
}