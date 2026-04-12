variable "bucket_name" {
  type        = string
  description = "Nome globalmente unico do bucket S3 usado para dados compartilhados do Terraform."
}

variable "force_destroy" {
  type        = bool
  description = "Quando true, permite destruir o bucket mesmo com objetos."
  default     = false
}
