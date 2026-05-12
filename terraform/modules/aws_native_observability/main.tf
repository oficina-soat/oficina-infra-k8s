locals {
  api_gateway_host = trimsuffix(
    trimprefix(
      trimprefix(coalesce(var.api_gateway_endpoint, ""), "https://"),
      format("%s://", "http")
    ),
    "/"
  )
  api_gateway_healthchecks_enabled       = var.enabled && var.api_gateway_enabled && var.enable_route53_healthchecks && local.api_gateway_host != ""
  api_gateway_latency_alarms_enabled     = var.enabled && var.api_gateway_enabled && try(trimspace(var.api_gateway_id), "") != ""
  api_gateway_access_log_metrics_enabled = var.enabled && var.api_gateway_access_logs_enabled && try(trimspace(var.api_gateway_access_log_group_name), "") != ""
  api_gateway_stage_prefix               = var.api_gateway_stage_name == "$default" ? "" : "/${trim(var.api_gateway_stage_name, "/")}"
  live_healthcheck_path                  = "${local.api_gateway_stage_prefix}${var.live_healthcheck_path}"
  ready_healthcheck_path                 = "${local.api_gateway_stage_prefix}${var.ready_healthcheck_path}"
  warning_alarm_actions                  = var.enabled ? [aws_sns_topic.warning[0].arn] : []
  critical_alarm_actions                 = var.enabled ? [aws_sns_topic.critical[0].arn] : []
  metric_namespace                       = "${var.metric_namespace}/${var.environment}"
  api_gateway_route_keys                 = sort(distinct(var.api_gateway_route_keys))
  api_gateway_route_metric_dimensions = {
    for route_key in local.api_gateway_route_keys : route_key => {
      api_method   = route_key == "$default" ? "$default" : split(" ", route_key)[0]
      api_resource = route_key == "$default" ? "$default" : split(" ", route_key)[1]
    } if route_key == "$default" || length(split(" ", route_key)) == 2
  }
  service_health_dashboard_enabled            = local.api_gateway_healthchecks_enabled || local.api_gateway_latency_alarms_enabled
  api_gateway_route_latency_dashboard_enabled = local.api_gateway_latency_alarms_enabled && length(local.api_gateway_route_metric_dimensions) > 0
  api_gateway_route_dashboard_keys            = sort(keys(local.api_gateway_route_metric_dimensions))
  api_gateway_dashboard_metric_keys           = local.api_gateway_latency_alarms_enabled ? ["api"] : []
  status_duration_states = {
    RECEBIDA             = "RECEBIDA"
    EM_DIAGNOSTICO       = "EM_DIAGNOSTICO"
    AGUARDANDO_APROVACAO = "AGUARDANDO_APROVACAO"
    EM_EXECUCAO          = "EM_EXECUCAO"
    FINALIZADA           = "FINALIZADA"
    ENTREGUE             = "ENTREGUE"
  }
  status_duration_metric_names = {
    RECEBIDA             = "OsStatusDurationMsRecebida"
    EM_DIAGNOSTICO       = "OsStatusDurationMsEmDiagnostico"
    AGUARDANDO_APROVACAO = "OsStatusDurationMsAguardandoAprovacao"
    EM_EXECUCAO          = "OsStatusDurationMsEmExecucao"
    FINALIZADA           = "OsStatusDurationMsFinalizada"
    ENTREGUE             = "OsStatusDurationMsEntregue"
  }
  status_transition_metric_names = {
    RECEBIDA             = "OsStatusTransitionsTotalRecebida"
    EM_DIAGNOSTICO       = "OsStatusTransitionsTotalEmDiagnostico"
    AGUARDANDO_APROVACAO = "OsStatusTransitionsTotalAguardandoAprovacao"
    EM_EXECUCAO          = "OsStatusTransitionsTotalEmExecucao"
    FINALIZADA           = "OsStatusTransitionsTotalFinalizada"
    ENTREGUE             = "OsStatusTransitionsTotalEntregue"
  }
  lambda_function_identifiers = [for function_name in var.lambda_function_names : trimspace(function_name) if trimspace(function_name) != ""]
  lambda_function_names = sort(distinct([
    for function_name in local.lambda_function_identifiers :
    startswith(function_name, "arn:") && can(regex("^arn:[^:]+:lambda:[^:]+:[^:]+:function:([^:]+)", function_name)[0])
    ? regex("^arn:[^:]+:lambda:[^:]+:[^:]+:function:([^:]+)", function_name)[0]
    : split(":", function_name)[0]
  ]))
  app_metrics_dashboard_start_y              = length(local.lambda_function_names) > 0 ? 18 : 12
  business_count_dashboard_period_seconds    = 86400
  business_duration_dashboard_period_seconds = 60
  k8s_dashboard_start_y                      = local.app_metrics_dashboard_start_y + 6
  k8s_dashboard_second_row                   = local.k8s_dashboard_start_y + 6
  logs_dashboard_start_y                     = local.k8s_dashboard_second_row + 6
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

resource "aws_cloudwatch_log_metric_filter" "os_status_transitions_total" {
  for_each = var.enabled ? local.status_duration_states : {}

  name           = "oficina-${var.environment}-os-status-transitions-${lower(replace(each.key, "_", "-"))}"
  log_group_name = aws_cloudwatch_log_group.app[0].name
  pattern        = "{ $.message = \"Transicao de ordem de servico concluida\" && $.mdc.ordem_servico_status_novo = \"${each.value}\" }"

  metric_transformation {
    name          = local.status_transition_metric_names[each.key]
    namespace     = local.metric_namespace
    value         = "1"
    default_value = 0
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
  count = var.enabled ? 1 : 0

  name           = "oficina-${var.environment}-os-processing-failures-total"
  log_group_name = aws_cloudwatch_log_group.app[0].name
  pattern        = "{ $.message = \"HTTP request completed\" && $.mdc.['url.path'] = \"*ordem-de-servico*\" && $.mdc.['http.status_code'] = \"5*\" }"

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
  measure_latency   = true

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
  measure_latency   = true

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

resource "aws_cloudwatch_metric_alarm" "api_route_latency_warning" {
  for_each = local.api_gateway_latency_alarms_enabled ? local.api_gateway_route_metric_dimensions : {}

  alarm_name          = "oficina-${var.environment}-api-route-${substr(md5(each.key), 0, 8)}-latency-warning"
  alarm_description   = "Warning: p95 de latencia da rota ${each.key} acima do limite."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.api_latency_warning_threshold_ms
  metric_name         = "Latency"
  namespace           = "AWS/ApiGateway"
  period              = 300
  extended_statistic  = "p95"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId    = var.api_gateway_id
    Method   = each.value["api_method"]
    Resource = each.value["api_resource"]
    Stage    = var.api_gateway_stage_name
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_route_latency_critical" {
  for_each = local.api_gateway_latency_alarms_enabled ? local.api_gateway_route_metric_dimensions : {}

  alarm_name          = "oficina-${var.environment}-api-route-${substr(md5(each.key), 0, 8)}-latency-critical"
  alarm_description   = "Critical: p95 de latencia da rota ${each.key} acima do limite severo."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.api_latency_critical_threshold_ms
  metric_name         = "Latency"
  namespace           = "AWS/ApiGateway"
  period              = 300
  extended_statistic  = "p95"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId    = var.api_gateway_id
    Method   = each.value["api_method"]
    Resource = each.value["api_resource"]
    Stage    = var.api_gateway_stage_name
  }

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx_warning" {
  count = local.api_gateway_latency_alarms_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-api-5xx-warning"
  alarm_description   = "Warning: respostas 5xx detectadas no API Gateway."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.api_5xx_warning_threshold
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_5xx_critical" {
  count = local.api_gateway_latency_alarms_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-api-5xx-critical"
  alarm_description   = "Critical: volume alto de respostas 5xx no API Gateway."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.api_5xx_critical_threshold
  metric_name         = "5xx"
  namespace           = "AWS/ApiGateway"
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_4xx_warning" {
  count = local.api_gateway_latency_alarms_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-api-4xx-warning"
  alarm_description   = "Warning: respostas 4xx detectadas no API Gateway."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.api_4xx_warning_threshold
  metric_name         = "4xx"
  namespace           = "AWS/ApiGateway"
  period              = var.alarm_period_seconds
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = var.api_gateway_id
    Stage = var.api_gateway_stage_name
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_4xx_critical" {
  count = local.api_gateway_latency_alarms_enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-api-4xx-critical"
  alarm_description   = "Critical: volume alto de respostas 4xx no API Gateway."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = var.api_4xx_critical_threshold
  metric_name         = "4xx"
  namespace           = "AWS/ApiGateway"
  period              = var.alarm_period_seconds
  statistic           = "Sum"
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
  count = var.enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-os-processing-failures-warning"
  alarm_description   = "Warning: falhas de processamento de OS detectadas nos logs do oficina-app."
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
  count = var.enabled ? 1 : 0

  alarm_name          = "oficina-${var.environment}-os-processing-failures-critical"
  alarm_description   = "Critical: volume alto de falhas de processamento de OS detectadas nos logs do oficina-app."
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

resource "aws_cloudwatch_metric_alarm" "k8s_memory_warning" {
  count = var.enabled && var.enable_k8s_resource_metrics ? 1 : 0

  alarm_name          = "oficina-${var.environment}-k8s-memory-warning"
  alarm_description   = "Warning: uso medio de memoria do ${var.k8s_app_namespace}/${var.k8s_app_service_name} acima do limite."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.k8s_memory_warning_threshold_bytes
  metric_name         = "container_memory_working_set_bytes"
  namespace           = "ContainerInsights/Prometheus"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    namespace   = var.k8s_app_namespace
    service     = var.k8s_app_service_name
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "k8s_memory_critical" {
  count = var.enabled && var.enable_k8s_resource_metrics ? 1 : 0

  alarm_name          = "oficina-${var.environment}-k8s-memory-critical"
  alarm_description   = "Critical: uso medio de memoria do ${var.k8s_app_namespace}/${var.k8s_app_service_name} acima do limite severo."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.k8s_memory_critical_threshold_bytes
  metric_name         = "container_memory_working_set_bytes"
  namespace           = "ContainerInsights/Prometheus"
  period              = var.alarm_period_seconds
  statistic           = "Average"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
    namespace   = var.k8s_app_namespace
    service     = var.k8s_app_service_name
  }

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "k8s_cpu_throttling_warning" {
  count = var.enabled && var.enable_k8s_resource_metrics ? 1 : 0

  alarm_name          = "oficina-${var.environment}-k8s-cpu-throttling-warning"
  alarm_description   = "Warning: throttling de CPU do ${var.k8s_app_namespace}/${var.k8s_app_service_name} acima do limite."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.k8s_cpu_throttling_warning_rate
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "throttle_rate"
    expression  = "RATE(throttle_total)"
    label       = "Taxa de throttling CPU"
    return_data = true
  }

  metric_query {
    id          = "throttle_total"
    return_data = false

    metric {
      metric_name = "container_cpu_cfs_throttled_seconds_total"
      namespace   = "ContainerInsights/Prometheus"
      period      = var.alarm_period_seconds
      stat        = "Average"

      dimensions = {
        ClusterName = var.cluster_name
        namespace   = var.k8s_app_namespace
        service     = var.k8s_app_service_name
      }
    }
  }

  alarm_actions = local.warning_alarm_actions
  ok_actions    = local.warning_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "k8s_cpu_throttling_critical" {
  count = var.enabled && var.enable_k8s_resource_metrics ? 1 : 0

  alarm_name          = "oficina-${var.environment}-k8s-cpu-throttling-critical"
  alarm_description   = "Critical: throttling de CPU do ${var.k8s_app_namespace}/${var.k8s_app_service_name} acima do limite severo."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = var.k8s_cpu_throttling_critical_rate
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "throttle_rate"
    expression  = "RATE(throttle_total)"
    label       = "Taxa de throttling CPU"
    return_data = true
  }

  metric_query {
    id          = "throttle_total"
    return_data = false

    metric {
      metric_name = "container_cpu_cfs_throttled_seconds_total"
      namespace   = "ContainerInsights/Prometheus"
      period      = var.alarm_period_seconds
      stat        = "Average"

      dimensions = {
        ClusterName = var.cluster_name
        namespace   = var.k8s_app_namespace
        service     = var.k8s_app_service_name
      }
    }
  }

  alarm_actions = local.critical_alarm_actions
  ok_actions    = local.critical_alarm_actions
  tags          = var.tags
}

resource "aws_cloudwatch_dashboard" "this" {
  count = var.enabled && var.enable_dashboard ? 1 : 0

  dashboard_name = "oficina-${var.environment}-observability"
  dashboard_body = jsonencode({
    start          = "-P7D"
    periodOverride = "inherit"
    widgets = [
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
          period  = local.business_count_dashboard_period_seconds
          view    = "timeSeries"
          stacked = false
          metrics = [
            [local.metric_namespace, "OsCreatedTotal", { id = "m1", visible = false }],
            [{ expression = "FILL(m1, 0)", id = "e1", label = "Ordens criadas por dia" }]
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
          title                = "Tempo medio por status"
          region               = var.region
          stat                 = "Average"
          period               = local.business_duration_dashboard_period_seconds
          view                 = "singleValue"
          stacked              = false
          setPeriodToTimeRange = true
          metrics = [
            [local.metric_namespace, local.status_duration_metric_names.RECEBIDA, { label = "RECEBIDA" }],
            [".", local.status_duration_metric_names.EM_DIAGNOSTICO, { label = "EM_DIAGNOSTICO" }],
            [".", local.status_duration_metric_names.AGUARDANDO_APROVACAO, { label = "AGUARDANDO_APROVACAO" }],
            [".", local.status_duration_metric_names.EM_EXECUCAO, { label = "EM_EXECUCAO" }],
            [".", local.status_duration_metric_names.FINALIZADA, { label = "FINALIZADA" }],
            [".", local.status_duration_metric_names.ENTREGUE, { label = "ENTREGUE" }]
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
          title   = "Transicoes diarias por status"
          region  = var.region
          stat    = "Sum"
          period  = local.business_count_dashboard_period_seconds
          view    = "timeSeries"
          stacked = false
          metrics = [
            [local.metric_namespace, local.status_transition_metric_names.RECEBIDA, { label = "RECEBIDA" }],
            [".", local.status_transition_metric_names.EM_DIAGNOSTICO, { label = "EM_DIAGNOSTICO" }],
            [".", local.status_transition_metric_names.AGUARDANDO_APROVACAO, { label = "AGUARDANDO_APROVACAO" }],
            [".", local.status_transition_metric_names.EM_EXECUCAO, { label = "EM_EXECUCAO" }],
            [".", local.status_transition_metric_names.FINALIZADA, { label = "FINALIZADA" }],
            [".", local.status_transition_metric_names.ENTREGUE, { label = "ENTREGUE" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Falhas diarias de integracao e processamento"
          region  = var.region
          stat    = "Sum"
          period  = local.business_count_dashboard_period_seconds
          view    = "timeSeries"
          stacked = false
          metrics = concat(
            [
              [local.metric_namespace, "IntegrationFailuresTotal", { label = "Falhas de integracao por dia" }]
            ],
            [
              [local.metric_namespace, "OsProcessingFailuresTotal", { label = "Falhas de processamento OS por dia" }]
            ]
          )
        }
      }
    ]
  })
}

resource "aws_cloudwatch_dashboard" "technical" {
  count = var.enabled && var.enable_dashboard ? 1 : 0

  dashboard_name = "oficina-${var.environment}-technical-observability"
  dashboard_body = jsonencode({
    widgets = concat(
      [
        for enabled in [local.api_gateway_latency_alarms_enabled] : {
          type   = "metric"
          x      = 0
          y      = 0
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
              [".", "IntegrationLatency", ".", ".", ".", ".", { label = "Integracao p95", stat = "p95" }],
              [".", "Latency", ".", ".", ".", ".", { label = "Media", stat = "Average" }],
              [".", "4xx", ".", ".", ".", ".", { label = "4xx", stat = "Sum", yAxis = "right" }],
              [".", "5xx", ".", ".", ".", ".", { label = "5xx", stat = "Sum", yAxis = "right" }]
            ]
          }
        } if enabled
      ],
      [
        for enabled in [local.service_health_dashboard_enabled] : {
          type   = "metric"
          x      = 12
          y      = 0
          width  = 12
          height = 6
          properties = {
            title   = "Disponibilidade e healthchecks por servico"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            yAxis = {
              left = {
                min   = 0
                max   = 100
                label = "%"
              }
            }
            metrics = concat(
              [
                for healthcheck in aws_route53_health_check.live :
                ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", healthcheck.id, { id = "app_live", visible = false, stat = "Minimum" }]
              ],
              [
                for healthcheck in aws_route53_health_check.ready :
                ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", healthcheck.id, { id = "app_ready", visible = false, stat = "Minimum" }]
              ],
              [
                for healthcheck in aws_route53_health_check.live :
                [{ expression = "app_live * 100", id = "app_live_pct", label = "oficina-app live ${local.live_healthcheck_path}" }]
              ],
              [
                for healthcheck in aws_route53_health_check.ready :
                [{ expression = "app_ready * 100", id = "app_ready_pct", label = "oficina-app ready ${local.ready_healthcheck_path}" }]
              ],
              [
                for metric_key in local.api_gateway_dashboard_metric_keys :
                ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, "Stage", var.api_gateway_stage_name, { id = "api_count", visible = false, stat = "Sum" }]
              ],
              [
                for metric_key in local.api_gateway_dashboard_metric_keys :
                [".", "5xx", ".", ".", ".", ".", { id = "api_5xx", visible = false, stat = "Sum" }]
              ],
              [
                for metric_key in local.api_gateway_dashboard_metric_keys :
                [{ expression = "IF(FILL(api_count, 0) > 0, 100 - 100 * FILL(api_5xx, 0) / FILL(api_count, 1), 100)", id = "api_success_pct", label = "API Gateway sem 5xx" }]
              ]
            )
          }
        } if enabled
      ],
      [
        for enabled in [local.api_gateway_route_latency_dashboard_enabled] : {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 12
          height = 6
          properties = {
            title   = "Latencia p95 por rota da API"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            metrics = [
              for route_key, route_metric in local.api_gateway_route_metric_dimensions :
              ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, "Method", route_metric["api_method"], "Resource", route_metric["api_resource"], "Stage", var.api_gateway_stage_name, { label = route_key, stat = "p95" }]
            ]
          }
        } if enabled
      ],
      [
        for enabled in [local.api_gateway_route_latency_dashboard_enabled] : {
          type   = "metric"
          x      = 12
          y      = 6
          width  = 12
          height = 6
          properties = {
            title   = "Saude HTTP por rota da API"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            yAxis = {
              left = {
                min   = 0
                max   = 100
                label = "% sem 5xx"
              }
            }
            metrics = concat(
              [
                for index, route_key in local.api_gateway_route_dashboard_keys :
                ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, "Method", local.api_gateway_route_metric_dimensions[route_key]["api_method"], "Resource", local.api_gateway_route_metric_dimensions[route_key]["api_resource"], "Stage", var.api_gateway_stage_name, { id = "r${index}_count", visible = false, stat = "Sum" }]
              ],
              [
                for index, route_key in local.api_gateway_route_dashboard_keys :
                [".", "5xx", ".", ".", ".", ".", ".", ".", ".", ".", { id = "r${index}_5xx", visible = false, stat = "Sum" }]
              ],
              [
                for index, route_key in local.api_gateway_route_dashboard_keys :
                [{ expression = "IF(FILL(r${index}_count, 0) > 0, 100 - 100 * FILL(r${index}_5xx, 0) / FILL(r${index}_count, 1), 100)", id = "r${index}_ok", label = "${route_key} sem 5xx" }]
              ]
            )
          }
        } if enabled
      ],
      [
        for enabled in [length(local.lambda_function_names) > 0] : {
          type   = "metric"
          x      = 0
          y      = 12
          width  = 24
          height = 6
          properties = {
            title   = "Lambdas - metricas tecnicas"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            yAxis = {
              left = {
                min   = 0
                label = "contagem"
              }
              right = {
                min   = 0
                label = "ms"
              }
            }
            metrics = concat(
              [
                for function_name in local.lambda_function_names :
                ["AWS/Lambda", "Invocations", "FunctionName", function_name, { label = "${function_name} invocacoes", stat = "Sum" }]
              ],
              [
                for function_name in local.lambda_function_names :
                [".", "Throttles", ".", function_name, { label = "${function_name} throttles", stat = "Sum" }]
              ],
              [
                for function_name in local.lambda_function_names :
                [".", "ConcurrentExecutions", ".", function_name, { label = "${function_name} concorrencia max", stat = "Maximum" }]
              ],
              [
                for function_name in local.lambda_function_names :
                [".", "Duration", ".", function_name, { label = "${function_name} duracao p95", stat = "p95", yAxis = "right" }]
              ]
            )
          }
        } if enabled
      ],
      flatten([
        for enabled in [var.enable_k8s_resource_metrics] : [
          {
            type   = "metric"
            x      = 0
            y      = local.app_metrics_dashboard_start_y
            width  = 12
            height = 6
            properties = {
              title   = "Latencia de integracoes do app"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service,env,integration,operation} MetricName=\"integration_latency_ms_max\" ClusterName=\"${var.cluster_name}\" namespace=\"default\" service=\"oficina-app\"', 'Maximum', 60)", id = "integration_latency", label = "Latencia max por integracao" }]
              ]
            }
          },
          {
            type   = "metric"
            x      = 12
            y      = local.app_metrics_dashboard_start_y
            width  = 12
            height = 6
            properties = {
              title   = "Falhas de integracao por tipo"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service,env,integration,operation,failure_type} MetricName=\"integration_failures_total\" ClusterName=\"${var.cluster_name}\" namespace=\"default\" service=\"oficina-app\"', 'Sum', 60)", id = "integration_failures", label = "Falhas por integracao/tipo" }]
              ]
            }
          }
        ] if enabled
      ]),
      flatten([
        for enabled in [var.enable_k8s_resource_metrics] : [
          {
            type   = "metric"
            x      = 0
            y      = local.k8s_dashboard_start_y
            width  = 12
            height = 6
            properties = {
              title   = "CPU k8s por servico"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service} MetricName=\"container_cpu_usage_seconds_total\" ClusterName=\"${var.cluster_name}\"', 'Sum', 60)", id = "cpu", label = "CPU por servico" }]
              ]
            }
          },
          {
            type   = "metric"
            x      = 12
            y      = local.k8s_dashboard_start_y
            width  = 12
            height = 6
            properties = {
              title   = "Memoria k8s por servico"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service} MetricName=\"container_memory_working_set_bytes\" ClusterName=\"${var.cluster_name}\"', 'Average', 60)", id = "mem", label = "Memoria por servico" }]
              ]
            }
          },
          {
            type   = "metric"
            x      = 0
            y      = local.k8s_dashboard_second_row
            width  = 12
            height = 6
            properties = {
              title   = "Rede k8s por servico"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service} MetricName=\"container_network_receive_bytes_total\" ClusterName=\"${var.cluster_name}\"', 'Sum', 60)", id = "rx", label = "Recebido" }],
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service} MetricName=\"container_network_transmit_bytes_total\" ClusterName=\"${var.cluster_name}\"', 'Sum', 60)", id = "tx", label = "Transmitido" }]
              ]
            }
          },
          {
            type   = "metric"
            x      = 12
            y      = local.k8s_dashboard_second_row
            width  = 12
            height = 6
            properties = {
              title   = "Throttling CPU k8s por servico"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service} MetricName=\"container_cpu_cfs_throttled_seconds_total\" ClusterName=\"${var.cluster_name}\"', 'Sum', 60)", id = "throttle", label = "Throttling CPU por servico" }]
              ]
            }
          }
        ] if enabled
      ]),
      [
        {
          type   = "log"
          x      = 0
          y      = local.logs_dashboard_start_y
          width  = 12
          height = 6
          properties = {
            title  = "Logs recentes de falhas de OS"
            region = var.region
            view   = "table"
            query  = "SOURCE '${var.app_log_group_name}' | fields @timestamp, mdc.request_id, mdc.trace_id, mdc.`url.path`, mdc.`http.status_code`, @message | filter @message like /HTTP request completed/ and @message like /ordem-de-servico/ and @message like /\"http.status_code\":\"5/ | sort @timestamp desc | limit 20"
          }
        },
        {
          type   = "log"
          x      = 12
          y      = local.logs_dashboard_start_y
          width  = 12
          height = 6
          properties = {
            title  = "Logs recentes de falhas de integracao"
            region = var.region
            view   = "table"
            query  = "SOURCE '${var.app_log_group_name}' | fields @timestamp, mdc.request_id, mdc.trace_id, mdc.integration_name, mdc.integration_operation, mdc.integration_failure_type, @message | filter @message like /Falha em integracao externa/ | sort @timestamp desc | limit 20"
          }
        }
      ],
      [
        for enabled in [local.api_gateway_access_log_metrics_enabled] : {
          type   = "log"
          x      = 0
          y      = local.logs_dashboard_start_y + 6
          width  = 24
          height = 6
          properties = {
            title  = "Access logs recentes com 5xx"
            region = var.region
            view   = "table"
            query  = "SOURCE '${var.api_gateway_access_log_group_name}' | fields @timestamp, requestId, correlationId, routeKey, path, status, integrationErrorMessage, errorMessage | filter status like /^5/ | sort @timestamp desc | limit 20"
          }
        } if enabled
      ]
    )
  })
}
