variable "name" {
  type        = string
  description = "Nome base dos recursos do NLB interno."
}

variable "vpc_id" {
  type        = string
  description = "VPC onde o NLB e o target group serao criados."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets usadas pelo NLB interno."
}

variable "listener_port" {
  type        = number
  description = "Porta exposta pelo listener interno do NLB."
}

variable "target_node_port" {
  type        = number
  description = "NodePort do Service Kubernetes que recebe o trafego do NLB."
}

variable "target_autoscaling_group_name" {
  type        = string
  description = "Auto Scaling Group do node group EKS registrado no target group."
}

variable "allowed_source_security_group_ids" {
  type        = list(string)
  description = "Security groups autorizados a acessar o listener do NLB."
}

variable "target_security_group_ids" {
  type        = list(string)
  description = "Security groups dos nodes que receberao entrada do NLB no NodePort."
}

variable "tags" {
  type        = map(string)
  description = "Tags adicionais dos recursos."
  default     = {}
}
