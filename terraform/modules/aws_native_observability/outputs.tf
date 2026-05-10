output "app_log_group_name" {
  value = try(aws_cloudwatch_log_group.app[0].name, null)
}

output "prometheus_log_group_name" {
  value = try(aws_cloudwatch_log_group.prometheus[0].name, null)
}

output "dashboard_name" {
  value = try(aws_cloudwatch_dashboard.this[0].dashboard_name, null)
}

output "technical_dashboard_name" {
  value = try(aws_cloudwatch_dashboard.technical[0].dashboard_name, null)
}

output "warning_topic_arn" {
  value = try(aws_sns_topic.warning[0].arn, null)
}

output "critical_topic_arn" {
  value = try(aws_sns_topic.critical[0].arn, null)
}

output "live_healthcheck_id" {
  value = try(aws_route53_health_check.live[0].id, null)
}

output "ready_healthcheck_id" {
  value = try(aws_route53_health_check.ready[0].id, null)
}
