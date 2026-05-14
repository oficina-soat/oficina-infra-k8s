variable "enabled" {
  type        = bool
  description = "Quando true, cria a stack AWS-native de observabilidade do ambiente."
  default     = true
}

variable "environment" {
  type        = string
  description = "Nome do ambiente."

  validation {
    condition     = trimspace(var.environment) != ""
    error_message = "environment nao pode ser vazio."
  }
}

variable "region" {
  type        = string
  description = "Regiao AWS do ambiente."

  validation {
    condition     = trimspace(var.region) != ""
    error_message = "region nao pode ser vazio."
  }
}

variable "cluster_name" {
  type        = string
  description = "Nome do cluster EKS."

  validation {
    condition     = trimspace(var.cluster_name) != ""
    error_message = "cluster_name nao pode ser vazio."
  }
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

  validation {
    condition     = var.api_gateway_id == null || trimspace(var.api_gateway_id) != ""
    error_message = "api_gateway_id deve ser nulo ou nao vazio."
  }
}

variable "api_gateway_endpoint" {
  type        = string
  description = "Endpoint base do HTTP API monitorado."
  default     = null
  nullable    = true

  validation {
    condition     = var.api_gateway_endpoint == null || trimspace(var.api_gateway_endpoint) != ""
    error_message = "api_gateway_endpoint deve ser nulo ou nao vazio."
  }
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

  validation {
    condition     = var.api_gateway_access_log_group_name == null || trimspace(var.api_gateway_access_log_group_name) != ""
    error_message = "api_gateway_access_log_group_name deve ser nulo ou nao vazio."
  }
}

variable "api_gateway_access_logs_enabled" {
  type        = bool
  description = "Quando true, os access logs do API Gateway estao habilitados neste ambiente."
  default     = false
}

variable "app_log_group_name" {
  type        = string
  description = "Log group dos logs estruturados do oficina-app no EKS."

  validation {
    condition     = trimspace(var.app_log_group_name) != ""
    error_message = "app_log_group_name nao pode ser vazio."
  }
}

variable "app_log_retention_in_days" {
  type        = number
  description = "Retencao dos logs estruturados do oficina-app."
  default     = 14

  validation {
    condition     = var.app_log_retention_in_days > 0
    error_message = "app_log_retention_in_days deve ser maior que zero."
  }
}

variable "prometheus_log_group_name" {
  type        = string
  description = "Log group dos eventos EMF gerados pelo CloudWatch agent Prometheus."

  validation {
    condition     = trimspace(var.prometheus_log_group_name) != ""
    error_message = "prometheus_log_group_name nao pode ser vazio."
  }
}

variable "prometheus_log_retention_in_days" {
  type        = number
  description = "Retencao do log group de Prometheus/EMF."
  default     = 7

  validation {
    condition     = var.prometheus_log_retention_in_days > 0
    error_message = "prometheus_log_retention_in_days deve ser maior que zero."
  }
}

variable "metric_namespace" {
  type        = string
  description = "Namespace das metricas customizadas derivadas de logs."
  default     = "Oficina/Observability"

  validation {
    condition     = trimspace(var.metric_namespace) != ""
    error_message = "metric_namespace nao pode ser vazio."
  }
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

variable "k8s_app_namespace" {
  type        = string
  description = "Namespace Kubernetes do servico principal monitorado nos alarmes de consumo."
  default     = "default"

  validation {
    condition     = trimspace(var.k8s_app_namespace) != ""
    error_message = "k8s_app_namespace nao pode ser vazio."
  }
}

variable "k8s_app_service_name" {
  type        = string
  description = "Nome do servico principal monitorado nos alarmes de consumo Kubernetes."
  default     = "oficina-app"

  validation {
    condition     = trimspace(var.k8s_app_service_name) != ""
    error_message = "k8s_app_service_name nao pode ser vazio."
  }
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

  validation {
    condition     = startswith(var.live_healthcheck_path, "/")
    error_message = "live_healthcheck_path deve comecar com '/'."
  }
}

variable "ready_healthcheck_path" {
  type        = string
  description = "Path HTTP usado no health check readiness."
  default     = "/q/health/ready"

  validation {
    condition     = startswith(var.ready_healthcheck_path, "/")
    error_message = "ready_healthcheck_path deve comecar com '/'."
  }
}

variable "api_latency_warning_threshold_ms" {
  type        = number
  description = "Threshold warning do p95 de latencia da API, em milissegundos."
  default     = 1500

  validation {
    condition     = var.api_latency_warning_threshold_ms >= 0
    error_message = "api_latency_warning_threshold_ms deve ser maior ou igual a zero."
  }
}

variable "api_latency_critical_threshold_ms" {
  type        = number
  description = "Threshold critical do p95 de latencia da API, em milissegundos."
  default     = 3000

  validation {
    condition     = var.api_latency_critical_threshold_ms >= 0
    error_message = "api_latency_critical_threshold_ms deve ser maior ou igual a zero."
  }
}

variable "api_5xx_warning_threshold" {
  type        = number
  description = "Quantidade de respostas 5xx no API Gateway para warning."
  default     = 1

  validation {
    condition     = var.api_5xx_warning_threshold >= 0
    error_message = "api_5xx_warning_threshold deve ser maior ou igual a zero."
  }
}

variable "api_5xx_critical_threshold" {
  type        = number
  description = "Quantidade de respostas 5xx no API Gateway para critical."
  default     = 3

  validation {
    condition     = var.api_5xx_critical_threshold >= 0
    error_message = "api_5xx_critical_threshold deve ser maior ou igual a zero."
  }
}

variable "api_4xx_warning_threshold" {
  type        = number
  description = "Quantidade de respostas 4xx no API Gateway para warning."
  default     = 10

  validation {
    condition     = var.api_4xx_warning_threshold >= 0
    error_message = "api_4xx_warning_threshold deve ser maior ou igual a zero."
  }
}

variable "api_4xx_critical_threshold" {
  type        = number
  description = "Quantidade de respostas 4xx no API Gateway para critical."
  default     = 30

  validation {
    condition     = var.api_4xx_critical_threshold >= 0
    error_message = "api_4xx_critical_threshold deve ser maior ou igual a zero."
  }
}

variable "integration_failures_warning_threshold" {
  type        = number
  description = "Quantidade de falhas de integracao no periodo para warning."
  default     = 1

  validation {
    condition     = var.integration_failures_warning_threshold >= 0
    error_message = "integration_failures_warning_threshold deve ser maior ou igual a zero."
  }
}

variable "integration_failures_critical_threshold" {
  type        = number
  description = "Quantidade de falhas de integracao no periodo para critical."
  default     = 3

  validation {
    condition     = var.integration_failures_critical_threshold >= 0
    error_message = "integration_failures_critical_threshold deve ser maior ou igual a zero."
  }
}

variable "os_processing_failures_warning_threshold" {
  type        = number
  description = "Quantidade de falhas de processamento de OS no periodo para warning."
  default     = 1

  validation {
    condition     = var.os_processing_failures_warning_threshold >= 0
    error_message = "os_processing_failures_warning_threshold deve ser maior ou igual a zero."
  }
}

variable "os_processing_failures_critical_threshold" {
  type        = number
  description = "Quantidade de falhas de processamento de OS no periodo para critical."
  default     = 3

  validation {
    condition     = var.os_processing_failures_critical_threshold >= 0
    error_message = "os_processing_failures_critical_threshold deve ser maior ou igual a zero."
  }
}

variable "k8s_memory_warning_threshold_bytes" {
  type        = number
  description = "Uso medio de memoria do servico Kubernetes principal para warning, em bytes."
  default     = 805306368

  validation {
    condition     = var.k8s_memory_warning_threshold_bytes > 0
    error_message = "k8s_memory_warning_threshold_bytes deve ser maior que zero."
  }
}

variable "k8s_memory_critical_threshold_bytes" {
  type        = number
  description = "Uso medio de memoria do servico Kubernetes principal para critical, em bytes."
  default     = 943718400

  validation {
    condition     = var.k8s_memory_critical_threshold_bytes > 0
    error_message = "k8s_memory_critical_threshold_bytes deve ser maior que zero."
  }
}

variable "k8s_cpu_throttling_warning_rate" {
  type        = number
  description = "Taxa de throttling de CPU do servico Kubernetes principal para warning, em segundos por segundo."
  default     = 0.10

  validation {
    condition     = var.k8s_cpu_throttling_warning_rate >= 0
    error_message = "k8s_cpu_throttling_warning_rate deve ser maior ou igual a zero."
  }
}

variable "k8s_cpu_throttling_critical_rate" {
  type        = number
  description = "Taxa de throttling de CPU do servico Kubernetes principal para critical, em segundos por segundo."
  default     = 0.25

  validation {
    condition     = var.k8s_cpu_throttling_critical_rate >= 0
    error_message = "k8s_cpu_throttling_critical_rate deve ser maior ou igual a zero."
  }
}

variable "alarm_period_seconds" {
  type        = number
  description = "Periodo base, em segundos, dos alarmes de negocio."
  default     = 300

  validation {
    condition     = var.alarm_period_seconds >= 60 && var.alarm_period_seconds % 60 == 0
    error_message = "alarm_period_seconds deve ser maior ou igual a 60 e multiplo de 60."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags propagadas para os recursos."
  default     = {}
}
