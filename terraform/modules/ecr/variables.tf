variable "repository_name" {
  type        = string
  description = "Nome do repositorio ECR."
}

variable "force_delete" {
  type        = bool
  description = "Quando true, permite destruir o repositorio ECR mesmo com imagens."
  default     = false
}
