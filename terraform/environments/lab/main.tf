data "aws_caller_identity" "current" {}

locals {
  azs = length(var.azs) > 0 ? slice(var.azs, 0, 2) : ["${var.region}a", "${var.region}b"]
  terraform_shared_data_bucket_name = coalesce(
    var.terraform_shared_data_bucket_name,
    "tf-shared-${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.region}"
  )
  api_gateway_name                        = coalesce(var.api_gateway_name, "${var.cluster_name}-http-api")
  expose_oficina_app_api_gateway          = var.create_api_gateway && var.expose_oficina_app_api_gateway
  oficina_app_private_nlb_name            = substr("${var.cluster_name}-oficina-app", 0, 29)
  api_gateway_vpc_link_security_group_ids = local.expose_oficina_app_api_gateway ? concat(var.api_gateway_vpc_link_security_group_ids, [aws_security_group.oficina_app_api_gateway_vpc_link[0].id]) : var.api_gateway_vpc_link_security_group_ids
  api_gateway_create_vpc_link_security_sg = local.expose_oficina_app_api_gateway ? false : var.api_gateway_create_vpc_link_security_group
  oficina_app_api_gateway_http_routes = local.expose_oficina_app_api_gateway ? {
    "ANY /" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "ANY /{proxy+}" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
  } : {}
  api_gateway_http_routes = merge(local.oficina_app_api_gateway_http_routes, var.api_gateway_http_routes)
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

resource "aws_security_group" "oficina_app_api_gateway_vpc_link" {
  count = local.expose_oficina_app_api_gateway ? 1 : 0

  name_prefix = "${local.api_gateway_name}-oficina-app-vpc-link-"
  description = "Security group do VPC Link para acessar o oficina-app"
  vpc_id      = module.network.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
    Name        = "${local.api_gateway_name}-oficina-app-vpc-link"
    Project     = "oficina"
  }
}

module "oficina_app_private_nlb" {
  count  = local.expose_oficina_app_api_gateway ? 1 : 0
  source = "../../modules/internal_nodeport_nlb"

  name                              = local.oficina_app_private_nlb_name
  vpc_id                            = module.network.vpc_id
  subnet_ids                        = module.network.public_subnet_ids
  listener_port                     = var.oficina_app_private_listener_port
  target_node_port                  = var.oficina_app_node_port
  target_autoscaling_group_name     = module.eks.node_group_autoscaling_group_name
  allowed_source_security_group_ids = local.api_gateway_vpc_link_security_group_ids
  target_security_group_ids         = [module.eks.cluster_security_group_id]

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
    Project     = "oficina"
  }
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
  vpc_link_security_group_ids          = local.api_gateway_vpc_link_security_group_ids
  create_vpc_link_security_group       = local.api_gateway_create_vpc_link_security_sg
  http_routes                          = local.api_gateway_http_routes
  lambda_routes                        = var.api_gateway_lambda_routes

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
    Project     = "oficina"
  }
}
