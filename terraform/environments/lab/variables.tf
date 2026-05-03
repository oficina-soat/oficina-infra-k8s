variable "region" {
  type        = string
  description = "Regiao AWS do laboratorio."
  default     = "us-east-1"
}

variable "cluster_name" {
  type        = string
  description = "Nome do cluster EKS do laboratorio."
  default     = "eks-lab"
}

variable "shared_infra_name" {
  type        = string
  description = "Prefixo compartilhado para recursos de identidade geral da suite, como VPC e bucket S3. Quando nulo, usa cluster_name."
  default     = null
  nullable    = true

  validation {
    condition     = var.shared_infra_name == null || trimspace(var.shared_infra_name) != ""
    error_message = "shared_infra_name nao pode ser vazio."
  }
}

variable "kubernetes_version" {
  type        = string
  description = "Versao do Kubernetes a ser usada pelo cluster EKS."
  default     = "1.35"
}

variable "azs" {
  type        = list(string)
  description = "Availability zones usadas pela VPC. Se vazio, usa duas zonas derivadas da regiao."
  default     = []

  validation {
    condition     = length(var.azs) == 0 || length(var.azs) >= 2
    error_message = "Informe pelo menos duas availability zones ou deixe vazio para usar o padrao."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs das subnets publicas quando a rede deste projeto precisar ser criada. Deve ter pelo menos dois valores."
  default     = ["10.0.0.0/20", "10.0.16.0/20"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Informe pelo menos dois CIDRs de subnets publicas."
  }
}

variable "network_vpc_cidr" {
  type        = string
  description = "CIDR da VPC criada automaticamente quando create_network_if_missing=true."
  default     = "10.0.0.0/16"
}

variable "vpc_id" {
  type        = string
  description = "VPC onde o EKS e recursos privados serao provisionados. Se omitido, o projeto pode reutilizar a rede do banco ou criar uma rede nova."
  default     = null
  nullable    = true

  validation {
    condition     = var.vpc_id == null || can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id deve ser nulo ou um ID de VPC valido."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Subnets usadas pelo EKS e recursos privados. Se vazia, usa as subnets publicas da rede reutilizada ou criada."
  default     = []

  validation {
    condition     = length(var.public_subnet_ids) == 0 || length(var.public_subnet_ids) >= 2
    error_message = "Informe pelo menos duas subnets publicas ou deixe vazio para resolucao automatica."
  }
}

variable "reuse_database_network" {
  type        = bool
  description = "Quando true, tenta reutilizar a VPC compartilhada criada pelo oficina-infra-db antes de criar uma rede propria."
  default     = true
}

variable "database_identifier" {
  type        = string
  description = "Identificador do RDS usado como sinal de que a rede compartilhada do oficina-infra-db ja foi provisionada."
  default     = "oficina-postgres-lab"

  validation {
    condition     = trimspace(var.database_identifier) != ""
    error_message = "database_identifier nao pode ser vazio."
  }
}

variable "create_network_if_missing" {
  type        = bool
  description = "Quando true, cria a VPC e subnets publicas se nenhuma rede reutilizavel ou explicita for resolvida."
  default     = true
}

variable "eks_cluster_role_arn" {
  type        = string
  description = "ARN da role existente usada pelo control plane do EKS."
  default     = "arn:aws:iam::998977374439:role/c198241a5073944l13625353t1w998977-LabEksClusterRole-V9LlUb7iwKB6"

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:role/.+$", var.eks_cluster_role_arn)) && !strcontains(var.eks_cluster_role_arn, "<")
    error_message = "eks_cluster_role_arn deve ser um ARN IAM de role valido, com account ID real de 12 digitos. Nao use placeholders como <account-id>."
  }
}

variable "eks_node_role_arn" {
  type        = string
  description = "ARN da role existente usada pelos nodes do EKS."
  default     = "arn:aws:iam::998977374439:role/c198241a5073944l13625353t1w998977374-LabEksNodeRole-7Kxx7p05maFv"

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:role/.+$", var.eks_node_role_arn)) && !strcontains(var.eks_node_role_arn, "<")
    error_message = "eks_node_role_arn deve ser um ARN IAM de role valido, com account ID real de 12 digitos. Nao use placeholders como <account-id>."
  }
}

variable "eks_access_principal_arn" {
  type        = string
  description = "Principal que recebe acesso administrativo ao cluster. Se omitido, o Terraform tenta usar a identidade atual."
  default     = null
  nullable    = true

  validation {
    condition = var.eks_access_principal_arn == null || (
      can(regex("^arn:(aws|aws-us-gov|aws-cn):iam::[0-9]{12}:(role|user)/.+$", var.eks_access_principal_arn)) &&
      !strcontains(var.eks_access_principal_arn, "<")
    )
    error_message = "eks_access_principal_arn deve ser nulo ou um ARN IAM valido de role/user, com account ID real de 12 digitos. Nao use placeholders como <account-id>."
  }
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia do managed node group."
  default     = "t3.medium"
}

variable "node_capacity_type" {
  type        = string
  description = "Tipo de capacidade do node group: ON_DEMAND (padrao) ou SPOT."
  default     = "ON_DEMAND"
}

variable "node_ami_type" {
  type        = string
  description = "AMI do managed node group."
  default     = "AL2023_x86_64_STANDARD"
}

variable "desired_size" {
  type        = number
  description = "Quantidade desejada de nodes."
  default     = 1
}

variable "min_size" {
  type        = number
  description = "Quantidade minima de nodes."
  default     = 1
}

variable "max_size" {
  type        = number
  description = "Quantidade maxima de nodes."
  default     = 1
}

variable "cluster_endpoint_public_access_cidrs" {
  type        = list(string)
  description = "Lista de CIDRs permitidos para acessar o endpoint publico do EKS."
  default     = ["0.0.0.0/0"]
}

variable "ecr_repository_name" {
  type        = string
  description = "Nome do repositorio ECR usado pela pipeline e pelo deployment da aplicacao."
  default     = "oficina"
}

variable "create_ecr_repository" {
  type        = bool
  description = "Quando true, o Terraform cria o repositorio ECR por padrao no lab. Quando false, reutiliza um repositorio existente."
  default     = true
}

variable "ecr_force_delete" {
  type        = bool
  description = "Quando true, permite destruir o repositorio ECR mesmo com imagens."
  default     = false
}

variable "create_terraform_shared_data_bucket" {
  type        = bool
  description = "Quando true, cria um bucket S3 para dados compartilhados do Terraform, incluindo backend remoto."
  default     = true
}

variable "terraform_shared_data_bucket_name" {
  type        = string
  description = "Nome do bucket S3 de dados compartilhados do Terraform. Se nulo, o nome e derivado de cluster, conta e regiao."
  default     = null
  nullable    = true

  validation {
    condition = var.terraform_shared_data_bucket_name == null || (
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.terraform_shared_data_bucket_name)) &&
      !strcontains(var.terraform_shared_data_bucket_name, "<")
    )
    error_message = "terraform_shared_data_bucket_name deve ser nulo ou um nome de bucket S3 valido, em minusculas e sem placeholders."
  }
}

variable "terraform_shared_data_bucket_force_destroy" {
  type        = bool
  description = "Quando true, permite destruir o bucket S3 de dados compartilhados mesmo com objetos."
  default     = false
}

variable "create_api_gateway" {
  type        = bool
  description = "Quando true, cria um API Gateway HTTP API para publicar a aplicacao principal e/ou Lambdas."
  default     = true
}

variable "api_gateway_name" {
  type        = string
  description = "Nome do API Gateway. Se nulo, usa `<cluster_name>-http-api`."
  default     = null
  nullable    = true
}

variable "api_gateway_stage_name" {
  type        = string
  description = "Nome do stage do API Gateway. O default `$default` evita custo e deploys extras."
  default     = "$default"
}

variable "api_gateway_enable_access_logs" {
  type        = bool
  description = "Quando true, habilita access logs do API Gateway em CloudWatch."
  default     = true
}

variable "api_gateway_access_log_retention_in_days" {
  type        = number
  description = "Retencao dos access logs do API Gateway em dias."
  default     = 14
}

variable "api_gateway_default_route_throttling_burst_limit" {
  type        = number
  description = "Burst limit padrao do API Gateway, ajustado para laboratorio."
  default     = 50
}

variable "api_gateway_default_route_throttling_rate_limit" {
  type        = number
  description = "Rate limit padrao do API Gateway, ajustado para laboratorio."
  default     = 25
}

variable "api_gateway_vpc_link_subnet_ids" {
  type        = list(string)
  description = "Subnets usadas pelo VPC Link quando houver rotas privadas. Se vazio, usa as subnets publicas da VPC do laboratorio."
  default     = []
}

variable "api_gateway_vpc_link_security_group_ids" {
  type        = list(string)
  description = "Security groups existentes para o VPC Link. Se vazio, o Terraform pode criar um SG dedicado."
  default     = []
}

variable "api_gateway_create_vpc_link_security_group" {
  type        = bool
  description = "Quando true e nenhum SG for informado, cria um security group dedicado para o VPC Link."
  default     = true
}

variable "expose_oficina_app_api_gateway" {
  type        = bool
  description = "Quando true, publica o oficina-app na raiz do HTTP API por VPC_LINK usando NLB interno e NodePort."
  default     = true
}

variable "oficina_app_api_gateway_jwt_authorizer_enabled" {
  type        = bool
  description = "Quando true, protege as rotas padrao do oficina-app com JWT authorizer nativo do HTTP API."
  default     = false
}

variable "oficina_app_api_gateway_jwt_issuer" {
  type        = string
  description = "Issuer esperado para os access tokens do oficina-app. Se nulo, usa o endpoint publico do proprio HTTP API."
  default     = null
  nullable    = true
}

variable "oficina_app_api_gateway_jwt_audience" {
  type        = list(string)
  description = "Audiences aceitas pelo JWT authorizer padrao do oficina-app."
  default     = ["oficina-app"]

  validation {
    condition = length(var.oficina_app_api_gateway_jwt_audience) == 0 || (
      length(var.oficina_app_api_gateway_jwt_audience) == 1 &&
      trimspace(var.oficina_app_api_gateway_jwt_audience[0]) == "oficina-app"
    )
    error_message = "oficina_app_api_gateway_jwt_audience deve permanecer alinhado ao contrato da suite: [\"oficina-app\"]."
  }
}

variable "oficina_app_api_gateway_jwt_scopes" {
  type        = list(string)
  description = "Scopes exigidos nas rotas protegidas padrao do oficina-app."
  default     = ["oficina-app"]

  validation {
    condition     = alltrue([for scope in var.oficina_app_api_gateway_jwt_scopes : trimspace(scope) != ""])
    error_message = "oficina_app_api_gateway_jwt_scopes nao pode conter scopes vazios."
  }
}

variable "oficina_app_private_listener_port" {
  type        = number
  description = "Porta privada do listener do NLB interno usado pelo API Gateway para acessar o oficina-app."
  default     = 8080

  validation {
    condition     = var.oficina_app_private_listener_port >= 1 && var.oficina_app_private_listener_port <= 65535
    error_message = "oficina_app_private_listener_port deve estar entre 1 e 65535."
  }
}

variable "oficina_app_node_port" {
  type        = number
  description = "NodePort fixo do Service Kubernetes oficina-app. Deve corresponder ao manifesto em k8s/base/oficina-app."
  default     = 30080

  validation {
    condition     = var.oficina_app_node_port >= 30000 && var.oficina_app_node_port <= 32767
    error_message = "oficina_app_node_port deve estar entre 30000 e 32767."
  }
}

variable "expose_mailhog_smtp_private_nlb" {
  type        = bool
  description = "Quando true, publica o SMTP do MailHog por NLB interno para uso da notificacao-lambda na VPC."
  default     = true
}

variable "mailhog_smtp_private_listener_port" {
  type        = number
  description = "Porta privada do listener do NLB interno usado para o SMTP do MailHog."
  default     = 1025

  validation {
    condition     = var.mailhog_smtp_private_listener_port >= 1 && var.mailhog_smtp_private_listener_port <= 65535
    error_message = "mailhog_smtp_private_listener_port deve estar entre 1 e 65535."
  }
}

variable "mailhog_smtp_node_port" {
  type        = number
  description = "NodePort fixo do Service Kubernetes mailhog-smtp-private. Deve corresponder ao manifesto em k8s/components/mailhog."
  default     = 31025

  validation {
    condition     = var.mailhog_smtp_node_port >= 30000 && var.mailhog_smtp_node_port <= 32767
    error_message = "mailhog_smtp_node_port deve estar entre 30000 e 32767."
  }
}

variable "notificacao_lambda_security_group_name" {
  type        = string
  description = "Nome do security group dedicado da notificacao-lambda para acessar recursos privados como o MailHog."
  default     = null
  nullable    = true
}

variable "observability_enabled" {
  type        = bool
  description = "Quando true, ativa a stack AWS-native de observabilidade do laboratorio."
  default     = true
}

variable "observability_environment_name" {
  type        = string
  description = "Nome do ambiente usado nos nomes de recursos de observabilidade."
  default     = "lab"
}

variable "observability_enable_dashboard" {
  type        = bool
  description = "Quando true, cria o dashboard CloudWatch consolidado."
  default     = true
}

variable "observability_enable_route53_healthchecks" {
  type        = bool
  description = "Quando true, cria health checks Route 53 para live e ready."
  default     = true
}

variable "observability_enable_k8s_resource_metrics" {
  type        = bool
  description = "Quando true, habilita a coleta minima de CPU e memoria do oficina-app via CloudWatch agent."
  default     = true
}

variable "observability_manage_node_role_policy_attachment" {
  type        = bool
  description = "Quando true, o Terraform tenta anexar CloudWatchAgentServerPolicy na IAM role dos nodes do EKS. Mantenha false quando o runner nao puder alterar IAM."
  default     = false
}

variable "observability_alert_email_endpoints" {
  type        = list(string)
  description = "Emails inscritos nos topicos SNS de alertas warning e critical."
  default     = []
}

variable "observability_app_log_retention_in_days" {
  type        = number
  description = "Retencao do log group com logs estruturados do oficina-app."
  default     = 14
}

variable "observability_prometheus_log_retention_in_days" {
  type        = number
  description = "Retencao do log group de eventos EMF do CloudWatch agent Prometheus."
  default     = 7
}

variable "observability_metric_namespace" {
  type        = string
  description = "Namespace das metricas customizadas derivadas de logs da Oficina."
  default     = "Oficina/Observability"
}

variable "observability_api_latency_warning_threshold_ms" {
  type        = number
  description = "Threshold warning do p95 de latencia da API, em milissegundos."
  default     = 1500
}

variable "observability_api_latency_critical_threshold_ms" {
  type        = number
  description = "Threshold critical do p95 de latencia da API, em milissegundos."
  default     = 3000
}

variable "observability_integration_failures_warning_threshold" {
  type        = number
  description = "Quantidade de falhas de integracao no periodo para warning."
  default     = 1
}

variable "observability_integration_failures_critical_threshold" {
  type        = number
  description = "Quantidade de falhas de integracao no periodo para critical."
  default     = 3
}

variable "observability_os_processing_failures_warning_threshold" {
  type        = number
  description = "Quantidade de falhas de processamento de OS no periodo para warning."
  default     = 1
}

variable "observability_os_processing_failures_critical_threshold" {
  type        = number
  description = "Quantidade de falhas de processamento de OS no periodo para critical."
  default     = 3
}

variable "observability_alarm_period_seconds" {
  type        = number
  description = "Periodo base dos alarmes de negocio, em segundos."
  default     = 300
}

variable "api_gateway_http_routes" {
  type = map(object({
    integration_uri      = string
    integration_method   = optional(string, "ANY")
    authorization_type   = optional(string, "NONE")
    authorizer_key       = optional(string)
    authorization_scopes = optional(list(string), [])
    connection_type      = optional(string, "INTERNET")
    timeout_milliseconds = optional(number, 30000)
  }))
  description = "Rotas HTTP_PROXY do API Gateway. Permite, por exemplo, publicar a aplicacao principal atras do gateway sem depender dela no apply quando o mapa estiver vazio."
  default     = {}
}

variable "api_gateway_jwt_authorizers" {
  type = map(object({
    issuer           = optional(string)
    audience         = list(string)
    identity_sources = optional(list(string), ["$request.header.Authorization"])
  }))
  description = "Authorizers JWT adicionais do API Gateway HTTP API."
  default     = {}
}

variable "api_gateway_lambda_routes" {
  type = map(object({
    invoke_arn             = string
    function_name          = optional(string)
    authorization_type     = optional(string, "NONE")
    authorizer_key         = optional(string)
    authorization_scopes   = optional(list(string), [])
    payload_format_version = optional(string, "2.0")
    timeout_milliseconds   = optional(number, 30000)
  }))
  description = "Rotas AWS_PROXY para Lambdas. Quando `function_name` for informado, o Terraform tambem cria a permissao de invocacao para o API Gateway."
  default     = {}
}
