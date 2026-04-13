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
  description = "CIDRs das subnets publicas. Deve ter pelo menos dois valores."
  default     = ["10.0.0.0/20", "10.0.16.0/20"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Informe pelo menos dois CIDRs de subnets publicas."
  }
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
  description = "Quando true, o Terraform cria o repositorio ECR. Quando false, reutiliza um repositorio existente."
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
