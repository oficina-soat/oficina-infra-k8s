variable "repository_name" {
  type        = string
  description = "Nome do repositorio ECR."
}

variable "create_repository" {
  type        = bool
  description = "Quando true, cria o repositorio ECR. Quando false, reutiliza um repositorio existente."
  default     = false
}

variable "force_delete" {
  type        = bool
  description = "Quando true, permite destruir o repositorio ECR mesmo com imagens."
  default     = false
}
