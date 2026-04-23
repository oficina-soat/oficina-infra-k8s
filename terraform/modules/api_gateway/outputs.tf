output "api_id" {
  value = aws_apigatewayv2_api.this.id
}

output "api_name" {
  value = aws_apigatewayv2_api.this.name
}

output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "api_execution_arn" {
  value = aws_apigatewayv2_api.this.execution_arn
}

output "stage_name" {
  value = aws_apigatewayv2_stage.this.name
}

output "stage_invoke_url" {
  value = aws_apigatewayv2_stage.this.invoke_url
}

output "http_route_keys" {
  value = keys(var.http_routes)
}

output "lambda_route_keys" {
  value = keys(var.lambda_routes)
}

output "jwt_authorizer_ids" {
  value = {
    for key, authorizer in aws_apigatewayv2_authorizer.jwt : key => authorizer.id
  }
}

output "vpc_link_id" {
  value = try(aws_apigatewayv2_vpc_link.this[0].id, null)
}

output "vpc_link_security_group_id" {
  value = try(aws_security_group.vpc_link[0].id, null)
}

output "access_log_group_name" {
  value = try(aws_cloudwatch_log_group.this[0].name, null)
}
