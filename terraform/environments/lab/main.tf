data "aws_caller_identity" "current" {}

locals {
  azs = length(var.azs) > 0 ? slice(var.azs, 0, 2) : ["${var.region}a", "${var.region}b"]
  terraform_shared_data_bucket_name = coalesce(
    var.terraform_shared_data_bucket_name,
    "tf-shared-${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.region}"
  )
  api_gateway_name = coalesce(var.api_gateway_name, "${var.cluster_name}-http-api")
}

module "network" {
  source = "../../modules/network"

  name                = var.cluster_name
  cluster_name        = var.cluster_name
  azs                 = local.azs
  public_subnet_cidrs = var.public_subnet_cidrs
}

module "eks" {
  source = "../../modules/eks"

  cluster_name                 = var.cluster_name
  kubernetes_version           = var.kubernetes_version
  cluster_role_arn             = var.eks_cluster_role_arn
  node_role_arn                = var.eks_node_role_arn
  subnet_ids                   = module.network.public_subnet_ids
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  access_principal_arn         = var.eks_access_principal_arn
  instance_type                = var.instance_type
  node_capacity_type           = var.node_capacity_type
  node_ami_type                = var.node_ami_type
  desired_size                 = var.desired_size
  min_size                     = var.min_size
  max_size                     = var.max_size
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name   = var.ecr_repository_name
  create_repository = var.create_ecr_repository
}

module "terraform_shared_data_bucket" {
  count  = var.create_terraform_shared_data_bucket ? 1 : 0
  source = "../../modules/terraform_shared_data_bucket"

  bucket_name   = local.terraform_shared_data_bucket_name
  force_destroy = var.terraform_shared_data_bucket_force_destroy
}

module "api_gateway" {
  count  = var.create_api_gateway ? 1 : 0
  source = "../../modules/api_gateway"

  name                                 = local.api_gateway_name
  stage_name                           = var.api_gateway_stage_name
  enable_access_logs                   = var.api_gateway_enable_access_logs
  access_log_retention_in_days         = var.api_gateway_access_log_retention_in_days
  default_route_throttling_burst_limit = var.api_gateway_default_route_throttling_burst_limit
  default_route_throttling_rate_limit  = var.api_gateway_default_route_throttling_rate_limit
  vpc_id                               = module.network.vpc_id
  vpc_link_subnet_ids                  = length(var.api_gateway_vpc_link_subnet_ids) > 0 ? var.api_gateway_vpc_link_subnet_ids : module.network.public_subnet_ids
  vpc_link_security_group_ids          = var.api_gateway_vpc_link_security_group_ids
  create_vpc_link_security_group       = var.api_gateway_create_vpc_link_security_group
  http_routes                          = var.api_gateway_http_routes
  lambda_routes                        = var.api_gateway_lambda_routes

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
    Project     = "oficina"
  }
}
