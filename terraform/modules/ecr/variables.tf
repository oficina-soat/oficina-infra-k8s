variable "repository_name" {
  type        = string
  description = "Nome do repositorio ECR."
}

variable "create_repository" {
  type        = bool
  description = "Quando true, cria o repositorio ECR. Quando false, reutiliza um repositorio existente."
  default     = false
}
