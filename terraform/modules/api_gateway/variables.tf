variable "name" {
  type        = string
  description = "Nome do API Gateway HTTP API."
}

variable "stage_name" {
  type        = string
  description = "Nome do stage publicado automaticamente."
  default     = "$default"
}

variable "enable_access_logs" {
  type        = bool
  description = "Quando true, habilita access logs em CloudWatch Logs."
  default     = true
}

variable "access_log_retention_in_days" {
  type        = number
  description = "Retencao dos access logs em dias."
  default     = 14
}

variable "default_route_throttling_burst_limit" {
  type        = number
  description = "Burst limit padrao das rotas do HTTP API."
  default     = 50
}

variable "default_route_throttling_rate_limit" {
  type        = number
  description = "Rate limit padrao das rotas do HTTP API."
  default     = 25
}

variable "vpc_id" {
  type        = string
  description = "VPC usada para criar o security group do VPC Link quando necessario."
  default     = null
  nullable    = true
}

variable "vpc_link_subnet_ids" {
  type        = list(string)
  description = "Subnets usadas pelo VPC Link quando alguma rota HTTP usar integracao privada."
  default     = []
}

variable "vpc_link_security_group_ids" {
  type        = list(string)
  description = "Security groups existentes a serem usados pelo VPC Link."
  default     = []
}

variable "create_vpc_link_security_group" {
  type        = bool
  description = "Quando true, cria um security group dedicado para o VPC Link se nenhum SG for informado."
  default     = true
}

variable "http_routes" {
  type = map(object({
    integration_uri      = string
    integration_method   = optional(string, "ANY")
    authorization_type   = optional(string, "NONE")
    authorizer_key       = optional(string)
    authorization_scopes = optional(list(string), [])
    connection_type      = optional(string, "INTERNET")
    timeout_milliseconds = optional(number, 30000)
  }))
  description = "Mapa de rotas HTTP_PROXY. A chave do mapa deve ser o route key, por exemplo `ANY /app/{proxy+}`."
  default     = {}
}

variable "jwt_authorizers" {
  type = map(object({
    issuer           = optional(string)
    audience         = list(string)
    identity_sources = optional(list(string), ["$request.header.Authorization"])
  }))
  description = "Authorizers JWT nativos do HTTP API. Quando issuer for nulo, usa o endpoint publico do proprio API Gateway."
  default     = {}
}

variable "lambda_routes" {
  type = map(object({
    invoke_arn             = string
    function_name          = optional(string)
    authorization_type     = optional(string, "NONE")
    authorizer_key         = optional(string)
    authorization_scopes   = optional(list(string), [])
    payload_format_version = optional(string, "2.0")
    timeout_milliseconds   = optional(number, 30000)
  }))
  description = "Mapa de rotas AWS_PROXY para Lambdas. A chave do mapa deve ser o route key, por exemplo `POST /payments`."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Tags adicionais dos recursos."
  default     = {}
}
