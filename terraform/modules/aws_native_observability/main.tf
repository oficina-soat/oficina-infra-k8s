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
  api_gateway_route_keys   = sort(distinct(var.api_gateway_route_keys))
  api_gateway_route_metric_dimensions = {
    for route_key in local.api_gateway_route_keys : route_key => {
      method   = route_key == "$default" ? "$default" : split(" ", route_key)[0]
      resource = route_key == "$default" ? "$default" : split(" ", route_key)[1]
    } if route_key == "$default" || length(split(" ", route_key)) == 2
  }
  service_health_dashboard_enabled = local.api_gateway_healthchecks_enabled || local.api_gateway_latency_alarms_enabled || length(local.lambda_function_names) > 0
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
  lambda_function_identifiers = [for function_name in var.lambda_function_names : trimspace(function_name) if trimspace(function_name) != ""]
  lambda_function_names = sort(distinct([
    for function_name in local.lambda_function_identifiers :
    startswith(function_name, "arn:") && can(regex("^arn:[^:]+:lambda:[^:]+:[^:]+:function:([^:]+)", function_name)[0])
    ? regex("^arn:[^:]+:lambda:[^:]+:[^:]+:function:([^:]+)", function_name)[0]
    : split(":", function_name)[0]
  ]))
  business_dashboard_period_seconds = 60
  k8s_dashboard_start_y             = length(local.lambda_function_names) > 0 ? 18 : 12
  k8s_dashboard_second_row          = local.k8s_dashboard_start_y + 6
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
    Method   = each.value.method
    Resource = each.value.resource
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
    Method   = each.value.method
    Resource = each.value.resource
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
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Volume de OS"
          region  = var.region
          stat    = "Sum"
          period  = local.business_dashboard_period_seconds
          view    = "timeSeries"
          stacked = false
          metrics = [
            [local.metric_namespace, "OsCreatedTotal", { id = "m1", visible = false }],
            [{ expression = "FILL(m1, 0)", id = "e1", label = "Ordens criadas" }]
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
          period               = local.business_dashboard_period_seconds
          view                 = "singleValue"
          stacked              = false
          setPeriodToTimeRange = true
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
          period  = local.business_dashboard_period_seconds
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
              [".", "Latency", ".", ".", ".", ".", { label = "Media", stat = "Average" }],
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
              local.api_gateway_healthchecks_enabled ? [
                ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.live[0].id, { id = "app_live", visible = false, stat = "Minimum" }],
                ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.ready[0].id, { id = "app_ready", visible = false, stat = "Minimum" }],
                [{ expression = "app_live * 100", id = "app_live_pct", label = "oficina-app live ${local.live_healthcheck_path}" }],
                [{ expression = "app_ready * 100", id = "app_ready_pct", label = "oficina-app ready ${local.ready_healthcheck_path}" }]
              ] : [],
              local.api_gateway_latency_alarms_enabled ? [
                ["AWS/ApiGateway", "Count", "ApiId", var.api_gateway_id, "Stage", var.api_gateway_stage_name, { id = "api_count", visible = false, stat = "Sum" }],
                [".", "5xx", ".", ".", ".", ".", { id = "api_5xx", visible = false, stat = "Sum" }],
                [{ expression = "IF(FILL(api_count, 0) > 0, 100 - 100 * FILL(api_5xx, 0) / FILL(api_count, 1), 100)", id = "api_success_pct", label = "API Gateway sem 5xx" }]
              ] : [],
              flatten([
                for index, function_name in local.lambda_function_names : [
                  ["AWS/Lambda", "Invocations", "FunctionName", function_name, { id = "l${index}_inv", visible = false, stat = "Sum" }],
                  [".", "Errors", ".", function_name, { id = "l${index}_err", visible = false, stat = "Sum" }],
                  [{ expression = "IF(FILL(l${index}_inv, 0) > 0, 100 - 100 * FILL(l${index}_err, 0) / FILL(l${index}_inv, 1), 100)", id = "l${index}_ok", label = "${function_name} sem erro" }]
                ]
              ])
            )
          }
        } if enabled
      ],
      [
        for enabled in [local.api_gateway_latency_alarms_enabled && length(local.api_gateway_route_metric_dimensions) > 0] : {
          type   = "metric"
          x      = 0
          y      = 6
          width  = 24
          height = 6
          properties = {
            title   = "Latencia p95 por rota da API"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            metrics = [
              for route_key, route_metric in local.api_gateway_route_metric_dimensions :
              ["AWS/ApiGateway", "Latency", "ApiId", var.api_gateway_id, "Method", route_metric.method, "Resource", route_metric.resource, "Stage", var.api_gateway_stage_name, { label = route_key, stat = "p95" }]
            ]
          }
        } if enabled
      ],
      [
        for enabled in [length(local.lambda_function_names) > 0] : {
          type   = "metric"
          x      = 0
          y      = 12
          width  = 12
          height = 6
          properties = {
            title   = "Lambdas - volume, erros e throttles"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            yAxis = {
              left = {
                min   = 0
                label = "invocacoes"
              }
              right = {
                min   = 0
                label = "erros e throttles"
              }
            }
            metrics = concat(
              [
                for function_name in local.lambda_function_names :
                ["AWS/Lambda", "Invocations", "FunctionName", function_name, { label = "${function_name} invocacoes", stat = "Sum" }]
              ],
              [
                for function_name in local.lambda_function_names :
                [".", "Errors", ".", function_name, { label = "${function_name} erros", stat = "Sum", yAxis = "right" }]
              ],
              [
                for function_name in local.lambda_function_names :
                [".", "Throttles", ".", function_name, { label = "${function_name} throttles", stat = "Sum", yAxis = "right" }]
              ]
            )
          }
        } if enabled
      ],
      [
        for enabled in [length(local.lambda_function_names) > 0] : {
          type   = "metric"
          x      = 12
          y      = 12
          width  = 12
          height = 6
          properties = {
            title   = "Lambdas - duracao p95"
            region  = var.region
            period  = 60
            view    = "timeSeries"
            stacked = false
            yAxis = {
              left = {
                min   = 0
                label = "ms"
              }
            }
            metrics = [
              for function_name in local.lambda_function_names :
              ["AWS/Lambda", "Duration", "FunctionName", function_name, { label = "${function_name} p95", stat = "p95" }]
            ]
          }
        } if enabled
      ],
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
              title   = "Filesystem k8s por servico"
              region  = var.region
              period  = 60
              view    = "timeSeries"
              stacked = false
              metrics = [
                [{ expression = "SEARCH('{ContainerInsights/Prometheus,ClusterName,namespace,service} MetricName=\"container_fs_usage_bytes\" ClusterName=\"${var.cluster_name}\"', 'Average', 60)", id = "fs", label = "Disco por servico" }]
              ]
            }
          }
        ] if enabled
      ])
    )
  })
}
