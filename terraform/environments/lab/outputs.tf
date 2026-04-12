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
