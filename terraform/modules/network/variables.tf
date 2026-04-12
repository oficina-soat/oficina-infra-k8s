variable "name" {
  type        = string
  description = "Prefixo usado para nomear os recursos de rede."
}

variable "cluster_name" {
  type        = string
  description = "Nome do cluster EKS para tagueamento das subnets."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR da VPC do laboratorio."
  default     = "10.0.0.0/16"
}

variable "azs" {
  type        = list(string)
  description = "Availability zones usadas pelas subnets publicas."

  validation {
    condition     = length(var.azs) >= 2
    error_message = "Informe pelo menos duas availability zones."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDRs das subnets publicas."
  default     = ["10.0.0.0/20", "10.0.16.0/20"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Informe pelo menos dois CIDRs de subnets publicas."
  }
}
