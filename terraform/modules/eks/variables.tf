variable "cluster_name" {
  type        = string
  description = "Nome do cluster EKS."
}

variable "kubernetes_version" {
  type        = string
  description = "Versao do Kubernetes a ser usada pelo cluster."
}

variable "cluster_role_arn" {
  type        = string
  description = "ARN da role existente usada pelo control plane do EKS."
}

variable "node_role_arn" {
  type        = string
  description = "ARN da role existente usada pelos nodes do EKS."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets usadas pelo cluster e pelo managed node group."
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  description = "Lista de CIDRs permitidos para acessar o endpoint publico do EKS."
  default     = ["0.0.0.0/0"]
}

variable "access_principal_arn" {
  type        = string
  description = "Principal que recebe acesso administrativo ao cluster. Se nulo, tenta usar a identidade atual."
  default     = null
  nullable    = true
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia do managed node group."
  default     = "t3.medium"
}

variable "node_capacity_type" {
  type        = string
  description = "Tipo de capacidade do node group: ON_DEMAND ou SPOT."
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
