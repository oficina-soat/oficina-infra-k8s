output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca" {
  value     = module.eks.cluster_ca
  sensitive = true
}

output "kubeconfig_command" {
  description = "Comando util para configurar o kubeconfig local via AWS CLI."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_name" {
  value = module.ecr.repository_name
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "terraform_shared_data_bucket_name" {
  description = "Bucket S3 criado para guardar dados compartilhados do Terraform, incluindo backend remoto."
  value       = try(module.terraform_shared_data_bucket[0].bucket_name, null)
}

output "terraform_shared_data_bucket_arn" {
  value = try(module.terraform_shared_data_bucket[0].bucket_arn, null)
}

output "api_gateway_id" {
  description = "ID do API Gateway HTTP API criado para o laboratorio."
  value       = try(module.api_gateway[0].api_id, null)
}

output "api_gateway_name" {
  value = try(module.api_gateway[0].api_name, null)
}

output "api_gateway_endpoint" {
  description = "Endpoint base do API Gateway HTTP API."
  value       = try(module.api_gateway[0].api_endpoint, null)
}

output "api_gateway_invoke_url" {
  description = "Invoke URL do stage do API Gateway."
  value       = try(module.api_gateway[0].stage_invoke_url, null)
}

output "api_gateway_execution_arn" {
  value = try(module.api_gateway[0].api_execution_arn, null)
}

output "api_gateway_http_route_keys" {
  value = try(module.api_gateway[0].http_route_keys, [])
}

output "api_gateway_lambda_route_keys" {
  value = try(module.api_gateway[0].lambda_route_keys, [])
}

output "api_gateway_jwt_authorizer_ids" {
  value = try(module.api_gateway[0].jwt_authorizer_ids, {})
}

output "api_gateway_vpc_link_id" {
  value = try(module.api_gateway[0].vpc_link_id, null)
}

output "api_gateway_vpc_link_security_group_id" {
  description = "Security group criado para o VPC Link. Se nulo, o gateway esta usando SGs externos ou nao possui integracoes privadas."
  value = try(coalesce(
    module.api_gateway[0].vpc_link_security_group_id,
    aws_security_group.oficina_app_api_gateway_vpc_link[0].id
  ), null)
}

output "oficina_app_public_base_url" {
  description = "URL publica base do oficina-app exposto na raiz do API Gateway."
  value       = try(module.api_gateway[0].stage_invoke_url, null)
}

output "oficina_app_private_nlb_dns_name" {
  description = "DNS privado do NLB interno usado pela integracao VPC_LINK do oficina-app."
  value       = try(module.oficina_app_private_nlb[0].load_balancer_dns_name, null)
}

output "oficina_app_private_nlb_listener_arn" {
  description = "Listener ARN usado como integration_uri das rotas raiz do oficina-app."
  value       = try(module.oficina_app_private_nlb[0].listener_arn, null)
}

output "oficina_app_node_port" {
  description = "NodePort do Service Kubernetes oficina-app usado como target do NLB interno."
  value       = var.oficina_app_node_port
}

output "mailhog_smtp_private_nlb_dns_name" {
  description = "DNS privado do NLB interno usado pela notificacao-lambda para acessar o SMTP do MailHog."
  value       = try(module.mailhog_smtp_private_nlb[0].load_balancer_dns_name, null)
}

output "mailhog_smtp_private_listener_port" {
  description = "Porta privada do listener do NLB interno usado para o SMTP do MailHog."
  value       = var.mailhog_smtp_private_listener_port
}

output "mailhog_smtp_node_port" {
  description = "NodePort do Service Kubernetes mailhog-smtp-private usado como target do NLB interno."
  value       = var.mailhog_smtp_node_port
}

output "notificacao_lambda_security_group_name" {
  description = "Nome do security group dedicado da notificacao-lambda para acesso privado na VPC."
  value       = try(aws_security_group.notificacao_lambda[0].name, null)
}

output "notificacao_lambda_security_group_id" {
  description = "ID do security group dedicado da notificacao-lambda para acesso privado na VPC."
  value       = try(aws_security_group.notificacao_lambda[0].id, null)
}

output "observability_app_log_group_name" {
  description = "Log group dos logs estruturados do oficina-app no CloudWatch Logs."
  value       = try(module.aws_native_observability[0].app_log_group_name, null)
}

output "observability_prometheus_log_group_name" {
  description = "Log group dos eventos EMF do CloudWatch agent Prometheus."
  value       = try(module.aws_native_observability[0].prometheus_log_group_name, null)
}

output "observability_dashboard_name" {
  description = "Nome do dashboard CloudWatch criado para observabilidade."
  value       = try(module.aws_native_observability[0].dashboard_name, null)
}

output "observability_warning_topic_arn" {
  description = "ARN do topico SNS usado para alertas warning."
  value       = try(module.aws_native_observability[0].warning_topic_arn, null)
}

output "observability_critical_topic_arn" {
  description = "ARN do topico SNS usado para alertas critical."
  value       = try(module.aws_native_observability[0].critical_topic_arn, null)
}

output "observability_live_healthcheck_id" {
  description = "ID do health check Route 53 de liveness."
  value       = try(module.aws_native_observability[0].live_healthcheck_id, null)
}

output "observability_ready_healthcheck_id" {
  description = "ID do health check Route 53 de readiness."
  value       = try(module.aws_native_observability[0].ready_healthcheck_id, null)
}
