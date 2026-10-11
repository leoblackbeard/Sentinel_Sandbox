locals {
  azs = ["eu-central-1a", "eu-central-1b"]
}

module "vpc_gateway" {
  source = "../../modules/vpc"

  name_prefix          = "gateway"
  vpc_cidr             = "10.10.0.0/16"
  azs                  = local.azs
  public_subnet_cidrs  = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnet_cidrs = ["10.10.10.0/24", "10.10.11.0/24"]

  tags = {
    Project = "sentinel"
    Tier    = "gateway"
  }
}

module "vpc_backend" {
  source = "../../modules/vpc"

  name_prefix          = "backend"
  vpc_cidr             = "10.20.0.0/16"
  azs                  = local.azs
  public_subnet_cidrs  = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnet_cidrs = ["10.20.10.0/24", "10.20.11.0/24"]

  tags = {
    Project = "sentinel"
    Tier    = "backend"
  }
}

module "peering" {
  source = "../../modules/peering"

  requester_vpc_id    = module.vpc_gateway.vpc_id
  accepter_vpc_id     = module.vpc_backend.vpc_id

  requester_cidr      = module.vpc_gateway.vpc_cidr
  accepter_cidr       = module.vpc_backend.vpc_cidr

  requester_route_table_id = module.vpc_gateway.private_route_table_id
  accepter_route_table_id  = module.vpc_backend.private_route_table_id

  tags = {
    Project = "sentinel"
  }
}

module "eks_gateway" {
  source = "../../modules/eks"

  cluster_name       = "eks-gateway"
  cluster_version    = "1.31"
  private_subnet_ids = module.vpc_gateway.private_subnet_ids

  instance_type = ["t3.medium"]
  desired_size  = 2
  min_size      = 2
  max_size      = 2
}

module "eks_backend" {
  source = "../../modules/eks"

  cluster_name       = "eks-backend"
  cluster_version    = "1.31"
  private_subnet_ids = module.vpc_backend.private_subnet_ids
  allowed_peer_cidr_blocks = [module.vpc_gateway.vpc_cidr]
  allowed_peer_port        = 8080

  instance_type = ["t3.medium"]
  desired_size  = 2
  min_size      = 2
  max_size      = 2
}