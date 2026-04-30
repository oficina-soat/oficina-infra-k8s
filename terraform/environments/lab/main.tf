data "aws_caller_identity" "current" {}

locals {
  azs = length(var.azs) > 0 ? slice(var.azs, 0, 2) : ["${var.region}a", "${var.region}b"]
  terraform_shared_data_bucket_name = coalesce(
    var.terraform_shared_data_bucket_name,
    "tf-shared-${var.cluster_name}-${data.aws_caller_identity.current.account_id}-${var.region}"
  )
  observability_app_log_group_name        = "/oficina/${var.observability_environment_name}/eks/oficina-app"
  observability_prometheus_log_group_name = "/aws/containerinsights/${var.cluster_name}/prometheus"
  api_gateway_name                        = coalesce(var.api_gateway_name, "${var.cluster_name}-http-api")
  expose_oficina_app_api_gateway          = var.create_api_gateway && var.expose_oficina_app_api_gateway
  oficina_app_authorizer_key              = "oficina-app"
  oficina_app_jwt_audience                = length(var.oficina_app_api_gateway_jwt_audience) > 0 ? var.oficina_app_api_gateway_jwt_audience : ["oficina-app"]
  oficina_app_jwt_scopes                  = length(var.oficina_app_api_gateway_jwt_scopes) > 0 ? var.oficina_app_api_gateway_jwt_scopes : ["oficina-app"]
  oficina_app_route_authorization_type    = var.oficina_app_api_gateway_jwt_authorizer_enabled ? "JWT" : "NONE"
  oficina_app_route_authorizer_key        = var.oficina_app_api_gateway_jwt_authorizer_enabled ? local.oficina_app_authorizer_key : null
  oficina_app_route_authorization_scopes  = var.oficina_app_api_gateway_jwt_authorizer_enabled ? local.oficina_app_jwt_scopes : []
  oficina_app_private_nlb_name            = substr("${var.cluster_name}-oficina-app", 0, 29)
  expose_mailhog_smtp_private_nlb         = var.expose_mailhog_smtp_private_nlb
  mailhog_smtp_private_nlb_name           = substr("${var.cluster_name}-mailhog-smtp", 0, 29)
  notificacao_lambda_security_group_name  = coalesce(var.notificacao_lambda_security_group_name, "${var.cluster_name}-notificacao-lambda")
  api_gateway_vpc_link_security_group_ids = local.expose_oficina_app_api_gateway ? concat(var.api_gateway_vpc_link_security_group_ids, [aws_security_group.oficina_app_api_gateway_vpc_link[0].id]) : var.api_gateway_vpc_link_security_group_ids
  api_gateway_create_vpc_link_security_sg = local.expose_oficina_app_api_gateway ? false : var.api_gateway_create_vpc_link_security_group
  oficina_app_api_gateway_http_routes = local.expose_oficina_app_api_gateway ? {
    "ANY /" = {
      integration_uri      = module.oficina_app_private_nlb[0].listener_arn
      connection_type      = "VPC_LINK"
      authorization_type   = local.oficina_app_route_authorization_type
      authorizer_key       = local.oficina_app_route_authorizer_key
      authorization_scopes = local.oficina_app_route_authorization_scopes
    }
    "ANY /{proxy+}" = {
      integration_uri      = module.oficina_app_private_nlb[0].listener_arn
      connection_type      = "VPC_LINK"
      authorization_type   = local.oficina_app_route_authorization_type
      authorizer_key       = local.oficina_app_route_authorizer_key
      authorization_scopes = local.oficina_app_route_authorization_scopes
    }
  } : {}
  oficina_app_api_gateway_public_http_routes = local.expose_oficina_app_api_gateway && var.oficina_app_api_gateway_jwt_authorizer_enabled ? {
    "GET /q/swagger-ui" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /q/swagger-ui/" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /q/swagger-ui/{proxy+}" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /q/health/live" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /q/health/ready" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /ordem-de-servico/{id}/acompanhar-link" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /ordem-de-servico/{id}/aprovar-link" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "POST /ordem-de-servico/{id}/aprovar-link" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "GET /ordem-de-servico/{id}/recusar-link" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
    "POST /ordem-de-servico/{id}/recusar-link" = {
      integration_uri = module.oficina_app_private_nlb[0].listener_arn
      connection_type = "VPC_LINK"
    }
  } : {}
  api_gateway_http_routes = merge(
    local.oficina_app_api_gateway_http_routes,
    local.oficina_app_api_gateway_public_http_routes,
    var.api_gateway_http_routes
  )
  api_gateway_jwt_authorizers = merge(
    var.api_gateway_jwt_authorizers,
    var.oficina_app_api_gateway_jwt_authorizer_enabled ? {
      (local.oficina_app_authorizer_key) = {
        issuer   = var.oficina_app_api_gateway_jwt_issuer
        audience = local.oficina_app_jwt_audience
      }
    } : {}
  )
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

resource "aws_security_group" "notificacao_lambda" {
  count = local.expose_mailhog_smtp_private_nlb ? 1 : 0

  name        = local.notificacao_lambda_security_group_name
  description = "Security group dedicado da notificacao-lambda no ambiente lab"
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
    Name        = local.notificacao_lambda_security_group_name
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

module "mailhog_smtp_private_nlb" {
  count  = local.expose_mailhog_smtp_private_nlb ? 1 : 0
  source = "../../modules/internal_nodeport_nlb"

  name                              = local.mailhog_smtp_private_nlb_name
  vpc_id                            = module.network.vpc_id
  subnet_ids                        = module.network.public_subnet_ids
  listener_port                     = var.mailhog_smtp_private_listener_port
  target_node_port                  = var.mailhog_smtp_node_port
  target_autoscaling_group_name     = module.eks.node_group_autoscaling_group_name
  allowed_source_security_group_ids = [aws_security_group.notificacao_lambda[0].id]
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
  jwt_authorizers                      = local.api_gateway_jwt_authorizers
  lambda_routes                        = var.api_gateway_lambda_routes

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
    Project     = "oficina"
  }
}

resource "aws_iam_role_policy_attachment" "eks_node_cloudwatch_agent" {
  count = var.observability_enabled ? 1 : 0

  role       = element(reverse(split("/", var.eks_node_role_arn)), 0)
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

module "aws_native_observability" {
  count  = var.observability_enabled ? 1 : 0
  source = "../../modules/aws_native_observability"

  enabled                                   = var.observability_enabled
  environment                               = var.observability_environment_name
  region                                    = var.region
  cluster_name                              = var.cluster_name
  api_gateway_id                            = try(module.api_gateway[0].api_id, null)
  api_gateway_endpoint                      = try(module.api_gateway[0].api_endpoint, null)
  api_gateway_stage_name                    = var.api_gateway_stage_name
  api_gateway_access_log_group_name         = try(module.api_gateway[0].access_log_group_name, null)
  app_log_group_name                        = local.observability_app_log_group_name
  app_log_retention_in_days                 = var.observability_app_log_retention_in_days
  prometheus_log_group_name                 = local.observability_prometheus_log_group_name
  prometheus_log_retention_in_days          = var.observability_prometheus_log_retention_in_days
  metric_namespace                          = var.observability_metric_namespace
  enable_dashboard                          = var.observability_enable_dashboard
  enable_k8s_resource_metrics               = var.observability_enable_k8s_resource_metrics
  enable_route53_healthchecks               = var.observability_enable_route53_healthchecks
  alert_email_endpoints                     = var.observability_alert_email_endpoints
  api_latency_warning_threshold_ms          = var.observability_api_latency_warning_threshold_ms
  api_latency_critical_threshold_ms         = var.observability_api_latency_critical_threshold_ms
  integration_failures_warning_threshold    = var.observability_integration_failures_warning_threshold
  integration_failures_critical_threshold   = var.observability_integration_failures_critical_threshold
  os_processing_failures_warning_threshold  = var.observability_os_processing_failures_warning_threshold
  os_processing_failures_critical_threshold = var.observability_os_processing_failures_critical_threshold
  alarm_period_seconds                      = var.observability_alarm_period_seconds

  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
    Project     = "oficina"
  }
}
