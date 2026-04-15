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

output "api_gateway_vpc_link_id" {
  value = try(module.api_gateway[0].vpc_link_id, null)
}

output "api_gateway_vpc_link_security_group_id" {
  description = "Security group criado para o VPC Link. Se nulo, o gateway esta usando SGs externos ou nao possui integracoes privadas."
  value       = try(module.api_gateway[0].vpc_link_security_group_id, null)
}
