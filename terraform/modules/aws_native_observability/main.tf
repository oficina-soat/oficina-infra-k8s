locals {
  api_gateway_healthchecks_enabled       = var.enabled && var.api_gateway_enabled && var.enable_route53_healthchecks
  api_gateway_latency_alarms_enabled     = var.enabled && var.api_gateway_enabled
  api_gateway_access_log_metrics_enabled = var.enabled && var.api_gateway_access_logs_enabled
  api_gateway_host = trimsuffix(
    trimprefix(
      trimprefix(coalesce(var.api_gateway_endpoint, ""), "https://"),
      "http://"
    ),
    "/"
  )
  api_gateway_stage_prefix = var.api_gateway_stage_name == "$default" ? "" : "/${trim(var.api_gateway_stage_name, "/")}"
  live_healthcheck_path    = "${local.api_gateway_stage_prefix}${var.live_healthcheck_path}"
  ready_healthcheck_path   = "${local.api_gateway_stage_prefix}${var.ready_healthcheck_path}"
  warning_alarm_actions    = var.enabled ? [aws_sns_topic.warning[0].arn] : []
  critical_alarm_actions   = var.enabled ? [aws_sns_topic.critical[0].arn] : []
  metric_namespace         = "${var.metric_namespace}/${var.environment}"
  status_duration_states = {
    RECEBIDA             = "RECEBIDA"
    EM_DIAGNOSTICO       = "EM_DIAGNOSTICO"
    AGUARDANDO_APROVACAO = "AGUARDANDO_APROVACAO"
    EM_EXECUCAO          = "EM_EXECUCAO"
    FINALIZADA           = "FINALIZADA"
  }
  status_duration_metric_names = {
    RECEBIDA             = "OsStatusDurationMsRecebida"
    EM_DIAGNOSTICO       = "OsStatusDurationMsEmDiagnostico"
    AGUARDANDO_APROVACAO = "OsStatusDurationMsAguardandoAprovacao"
    EM_EXECUCAO          = "OsStatusDurationMsEmExecucao"
    FINALIZADA           = "OsStatusDurationMsFinalizada"
  }
}

resource "aws_cloudwatch_log_group" "app" {
  count = var.enabled ? 1 : 0

  name              = var.app_log_group_name
  retention_in_days = var.app_log_retention_in_days

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "prometheus" {
  count = var.enabled && var.enable_k8s_resource_metrics ? 1 : 0

  name              = var.prometheus_log_group_name
  retention_in_days = var.prometheus_log_retention_in_days

  tags = var.tags
}

resource "aws_sns_topic" "warning" {
  count = var.enabled ? 1 : 0

  name = "oficina-${var.environment}-observability-warning"
  tags = var.tags
}

resource "aws_sns_topic" "critical" {
  count = var.enabled ? 1 : 0

  name = "oficina-${var.environment}-observability-critical"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "warning_email" {
  for_each = var.enabled ? toset(var.alert_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.warning[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic_subscription" "critical_email" {
  for_each = var.enabled ? toset(var.alert_email_endpoints) : toset([])

  topic_arn = aws_sns_topic.critical[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_log_metric_filter" "os_created_total" {
  count = var.enabled ? 1 : 0

  name           = "oficina-${var.environment}-os-created-total"
  log_group_name = aws_cloudwatch_log_group.app[0].name
  pattern        = "{ $.message = \"Ordem de servico criada\" }"

  metric_transformation {
    name          = "OsCreatedTotal"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_log_metric_filter" "os_status_duration_ms" {
  for_each = var.enabled ? local.status_duration_states : {}

  name           = "oficina-${var.environment}-os-status-duration-${lower(replace(each.key, "_", "-"))}"
  log_group_name = aws_cloudwatch_log_group.app[0].name
  pattern        = "{ $.message = \"Transicao de ordem de servico concluida\" && $.mdc.ordem_servico_status_anterior = \"${each.value}\" && $.mdc.ordem_servico_status_duration_ms = * }"

  metric_transformation {
    name      = local.status_duration_metric_names[each.key]
    namespace = local.metric_namespace
    value     = "$.mdc.ordem_servico_status_duration_ms"
    unit      = "Milliseconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "integration_failures_total" {
  count = var.enabled ? 1 : 0

  name           = "oficina-${var.environment}-integration-failures-total"
  log_group_name = aws_cloudwatch_log_group.app[0].name
  pattern        = "{ $.message = \"Falha em integracao externa\" && $.mdc.integration_name = * && $.mdc.integration_operation = * }"

  metric_transformation {
    name          = "IntegrationFailuresTotal"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_log_metric_filter" "os_processing_failures_total" {
  count = local.api_gateway_access_log_metrics_enabled ? 1 : 0

  name           = "oficina-${var.environment}-os-processing-failures-total"
  log_group_name = var.api_gateway_access_log_group_name
  pattern        = "{ $.path = \"*ordem-de-servico*\" && $.status = 5* }"

  metric_transformation {
    name          = "OsProcessingFailuresTotal"
    namespace     = local.metric_namespace
    value         = "1"
    default_value = 0
  }
}

resource "aws_route53_health_check" "live" {
  count = local.api_gateway_healthchecks_enabled ? 1 : 0

  fqdn              = local.api_gateway_host
  port              = 443
  type              = "HTTPS"
  resource_path     = local.live_healthcheck_path
  request_interval  = 30
  failure_threshold = 3

  tags = merge(var.tags, {
    Name     = "oficina-${var.environment}-live"
    Severity = "critical"
  })
}

resource "aws_route53_health_check" "ready" {
  count = local.api_gateway_healthchecks_enabled ? 1 : 0

  fqdn              = local.api_gateway_host
  port              = 443
  type              = "HTTPS"
  resource_path     = local.ready_healthcheck_path
  request_interval  = 30
  failure_threshold = 3

  tags = merge(var.tags, {
    Name     = "oficina-${var.environment}-ready"
    Severity = "warning"
  })
}

resource "aws_cloudwatch_metric_alarm" "uptime_live_critical" {
  count = local.api_gateway_healthchecks_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-uptime-live-critical"
  alarm_description   = "Critical: healthcheck live do oficina-app indisponivel."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.live[0].id
  }

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "uptime_ready_warning" {
  count = local.api_gateway_healthchecks_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-uptime-ready-warning"
  alarm_description   = "Warning: healthcheck ready do oficina-app degradado."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.ready[0].id
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_latency_warning" {
  count = local.api_gateway_latency_alarms_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-api-latency-warning"
  alarm_description   = "Warning: p95 de latencia do API Gateway acima do limite."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.api_latency_warning_threshold_ms
  metric_name         = "Latency"
  namespace           = "AWS/ApiGateway"
  period              = 300
  extended_statistic  = "p95"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_latency_critical" {
  count = local.api_gateway_latency_alarms_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-api-latency-critical"
  alarm_description   = "Critical: p95 de latencia do API Gateway acima do limite severo."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.api_latency_critical_threshold_ms
  metric_name         = "Latency"
  namespace           = "AWS/ApiGateway"
  period              = 300
  extended_statistic  = "p95"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "integration_failures_warning" {
  count = var.enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-integration-failures-warning"
  alarm_description   = "Warning: falhas de integracao externas detectadas no oficina-app."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.integration_failures_warning_threshold
  metric_name         = aws_cloudwatch_log_metric_filter.integration_failures_total[0].metric_transformation[0].name
  namespace           = local.metric_namespace
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "integration_failures_critical" {
  count = var.enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-integration-failures-critical"
  alarm_description   = "Critical: volume alto de falhas de integracao externas no oficina-app."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.integration_failures_critical_threshold
  metric_name         = aws_cloudwatch_log_metric_filter.integration_failures_total[0].metric_transformation[0].name
  namespace           = local.metric_namespace
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "os_processing_failures_warning" {
  count = local.api_gateway_access_log_metrics_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-os-processing-failures-warning"
  alarm_description   = "Warning: falhas de processamento de OS detectadas no gateway."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.os_processing_failures_warning_threshold
  metric_name         = aws_cloudwatch_log_metric_filter.os_processing_failures_total[0].metric_transformation[0].name
  namespace           = local.metric_namespace
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "os_processing_failures_critical" {
  count = local.api_gateway_access_log_metrics_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-os-processing-failures-critical"
  alarm_description   = "Critical: volume alto de falhas de processamento de OS detectadas no gateway."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.os_processing_failures_critical_threshold
  metric_name         = aws_cloudwatch_log_metric_filter.os_processing_failures_total[0].metric_transformation[0].name
  namespace           = local.metric_namespace
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_dashboard" "this" {
  count = var.enabled && var.enable_dashboard ? 1 : 0

  dashboard_name = "oficina-${var.environment}-observability"
  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "metric"
          x      = 0
          y      = 0
          width  = 12
          height = 6
          properties = {
            title   = "Volume diario de OS"
            region  = var.region
            stat    = "Sum"
            period  = 86400
            view    = "timeSeries"
            stacked = false
            metrics = [
              [local.metric_namespace, "OsCreatedTotal", { label = "Ordens criadas por dia" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 0
          width  = 12
          height = 6
          properties = {
            title   = "Tempo medio por status"
            region  = var.region
            stat    = "Average"
            period  = 3600
            view    = "timeSeries"
            stacked = false
            metrics = [
              [local.metric_namespace, local.status_duration_metric_names.RECEBIDA, { label = "RECEBIDA" }],
              [".", local.status_duration_metric_names.EM_DIAGNOSTICO, { label = "EM_DIAGNOSTICO" }],
              [".", local.status_duration_metric_names.AGUARDANDO_APROVACAO, { label = "AGUARDANDO_APROVACAO" }],
              [".", local.status_duration_metric_names.EM_EXECUCAO, { label = "EM_EXECUCAO" }],
              [".", local.status_duration_metric_names.FINALIZADA, { label = "FINALIZADA" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 12
          height = 6
          properties = {
            title   = "Falhas de integracao e processamento"
            region  = var.region
            stat    = "Sum"
            period  = 300
            view    = "timeSeries"
            stacked = false
            metrics = concat(
              [
                [local.metric_namespace, "IntegrationFailuresTotal", { label = "Falhas de integracao" }]
              ],
              local.api_gateway_access_log_metrics_enabled ? [
                [local.metric_namespace, "OsProcessingFailuresTotal", { label = "Falhas de processamento OS" }]
              ] : []
            )
          }
        }
      ],
      local.api_gateway_latency_alarms_enabled ? [
        {
          type   = "metric"
          x      = 12
          y      = 6
          width  = 12
          height = 6
          properties = {
            title   = "Latencia da API"
            region  = var.region
            period  = 300
            view    = "timeSeries"
            stacked = false
            metrics = [
              ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, "Stage", var.api_gateway_stage_name, { label = "p95", stat = "p95" }],
              [".", "Latency", ".", ".", ".", ".", { label = "Media", stat = "Average" }]
            ]
          }
        }
      ] : [],
      var.enable_k8s_resource_metrics ? [
        {
          type   = "metric"
          x      = 0
          y      = 12
          width  = 12
          height = 6
          properties = {
            title   = "Consumo de recursos k8s do oficina-app"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            metrics = [
              ["ContainerInsights/Prometheus", "container_cpu_usage_seconds_total", "ClusterName", var.cluster_name, "namespace", "default", "container", "oficina-app", { id = "m1", stat = "Sum", visible = false }],
              [{ expression = "(m1/60)*1000", id = "e1", label = "CPU (mCPU)" }],
              ["ContainerInsights/Prometheus", "container_memory_working_set_bytes", "ClusterName", var.cluster_name, "namespace", "default", "container", "oficina-app", { id = "m2", stat = "Average", visible = false }],
              [{ expression = "m2/1048576", id = "e2", label = "Memoria (MiB)", yAxis = "right" }]
            ]
          }
        }
      ] : [],
      local.api_gateway_healthchecks_enabled ? [
        {
          type   = "metric"
          x      = 12
          y      = 12
          width  = 12
          height = 6
          properties = {
            title   = "Uptime e healthchecks"
            region  = var.region
            period  = 60
            stat    = "Minimum"
            view    = "timeSeries"
            stacked = false
            metrics = [
              ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.live[0].id, { label = "Live" }],
              [".", "HealthCheckStatus", ".", aws_route53_health_check.ready[0].id, { label = "Ready" }]
            ]
          }
        }
      ] : []
    )
  })
}
