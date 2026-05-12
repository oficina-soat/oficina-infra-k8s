variable "enabled" {
  type        = bool
  description = "Quando true, cria a stack AWS-native de observabilidade do ambiente."
  default     = true
}

variable "environment" {
  type        = string
  description = "Nome do ambiente."
}

variable "region" {
  type        = string
  description = "Regiao AWS do ambiente."
}

variable "cluster_name" {
  type        = string
  description = "Nome do cluster EKS."
}

variable "api_gateway_enabled" {
  type        = bool
  description = "Quando true, a stack observa um API Gateway gerenciado neste ambiente."
  default     = false
}

variable "api_gateway_id" {
  type        = string
  description = "ID do HTTP API monitorado."
  default     = null
  nullable    = true
}

variable "api_gateway_endpoint" {
  type        = string
  description = "Endpoint base do HTTP API monitorado."
  default     = null
  nullable    = true
}

variable "api_gateway_stage_name" {
  type        = string
  description = "Nome do stage do HTTP API."
  default     = "$default"
}

variable "api_gateway_route_keys" {
  type        = list(string)
  description = "Route keys publicados no HTTP API para metricas e alarmes por rota."
  default     = []
}

variable "api_gateway_access_log_group_name" {
  type        = string
  description = "Log group dos access logs do API Gateway."
  default     = null
  nullable    = true
}

variable "api_gateway_access_logs_enabled" {
  type        = bool
  description = "Quando true, os access logs do API Gateway estao habilitados neste ambiente."
  default     = false
}

variable "app_log_group_name" {
  type        = string
  description = "Log group dos logs estruturados do oficina-app no EKS."
}

variable "app_log_retention_in_days" {
  type        = number
  description = "Retencao dos logs estruturados do oficina-app."
  default     = 14
}

variable "prometheus_log_group_name" {
  type        = string
  description = "Log group dos eventos EMF gerados pelo CloudWatch agent Prometheus."
}

variable "prometheus_log_retention_in_days" {
  type        = number
  description = "Retencao do log group de Prometheus/EMF."
  default     = 7
}

variable "metric_namespace" {
  type        = string
  description = "Namespace das metricas customizadas derivadas de logs."
  default     = "Oficina/Observability"
}

variable "enable_dashboard" {
  type        = bool
  description = "Quando true, cria os dashboards CloudWatch de observabilidade."
  default     = true
}

variable "enable_k8s_resource_metrics" {
  type        = bool
  description = "Quando true, prepara o log group para metricas Prometheus/cAdvisor do oficina-app."
  default     = true
}

variable "lambda_function_names" {
  type        = list(string)
  description = "Nomes das funcoes Lambda que devem aparecer no dashboard tecnico."
  default     = []
}

variable "enable_route53_healthchecks" {
  type        = bool
  description = "Quando true, cria health checks Route 53 para live e ready."
  default     = true
}

variable "alert_email_endpoints" {
  type        = list(string)
  description = "Lista de emails inscritos nos topicos SNS de alerta."
  default     = []
}

variable "live_healthcheck_path" {
  type        = string
  description = "Path HTTP usado no health check liveness."
  default     = "/q/health/live"
}

variable "ready_healthcheck_path" {
  type        = string
  description = "Path HTTP usado no health check readiness."
  default     = "/q/health/ready"
}

variable "api_latency_warning_threshold_ms" {
  type        = number
  description = "Threshold warning do p95 de latencia da API, em milissegundos."
  default     = 1500
}

variable "api_latency_critical_threshold_ms" {
  type        = number
  description = "Threshold critical do p95 de latencia da API, em milissegundos."
  default     = 3000
}

variable "api_5xx_warning_threshold" {
  type        = number
  description = "Quantidade de respostas 5xx no API Gateway para warning."
  default     = 1
}

variable "api_5xx_critical_threshold" {
  type        = number
  description = "Quantidade de respostas 5xx no API Gateway para critical."
  default     = 3
}

variable "api_4xx_warning_threshold" {
  type        = number
  description = "Quantidade de respostas 4xx no API Gateway para warning."
  default     = 10
}

variable "api_4xx_critical_threshold" {
  type        = number
  description = "Quantidade de respostas 4xx no API Gateway para critical."
  default     = 30
}

variable "integration_failures_warning_threshold" {
  type        = number
  description = "Quantidade de falhas de integracao no periodo para warning."
  default     = 1
}

variable "integration_failures_critical_threshold" {
  type        = number
  description = "Quantidade de falhas de integracao no periodo para critical."
  default     = 3
}

variable "os_processing_failures_warning_threshold" {
  type        = number
  description = "Quantidade de falhas de processamento de OS no periodo para warning."
  default     = 1
}

variable "os_processing_failures_critical_threshold" {
  type        = number
  description = "Quantidade de falhas de processamento de OS no periodo para critical."
  default     = 3
}

variable "alarm_period_seconds" {
  type        = number
  description = "Periodo base, em segundos, dos alarmes de negocio."
  default     = 300
}

variable "tags" {
  type        = map(string)
  description = "Tags propagadas para os recursos."
  default     = {}
}
