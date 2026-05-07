locals {
  http_routes   = var.http_routes
  lambda_routes = var.lambda_routes
  uses_vpc_link = length([
    for route in values(local.http_routes) : route
    if upper(route.connection_type) == "VPC_LINK"
  ]) > 0
}

resource "aws_cloudwatch_log_group" "this" {
  count = var.enable_access_logs ? 1 : 0

  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.access_log_retention_in_days

  tags = var.tags
}

resource "aws_security_group" "vpc_link" {
  count = local.uses_vpc_link && var.create_vpc_link_security_group && length(var.vpc_link_security_group_ids) == 0 ? 1 : 0

  name_prefix = "${var.name}-apigw-vpc-link-"
  description = "Security group do VPC Link do API Gateway ${var.name}"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    precondition {
      condition     = var.vpc_id != null
      error_message = "vpc_id deve ser informado para criar automaticamente o security group do VPC Link."
    }
  }

  tags = merge(var.tags, {
    Name = "${var.name}-apigw-vpc-link"
  })
}

resource "aws_apigatewayv2_vpc_link" "this" {
  count = local.uses_vpc_link ? 1 : 0

  name               = "${var.name}-vpc-link"
  subnet_ids         = var.vpc_link_subnet_ids
  security_group_ids = length(var.vpc_link_security_group_ids) > 0 ? var.vpc_link_security_group_ids : aws_security_group.vpc_link[*].id

  lifecycle {
    precondition {
      condition     = length(var.vpc_link_subnet_ids) > 0
      error_message = "vpc_link_subnet_ids deve ter ao menos uma subnet quando existir rota HTTP com connection_type = VPC_LINK."
    }
  }

  tags = var.tags
}

resource "aws_apigatewayv2_api" "this" {
  name          = var.name
  protocol_type = "HTTP"

  tags = var.tags
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  for_each = var.jwt_authorizers

  api_id           = aws_apigatewayv2_api.this.id
  authorizer_type  = "JWT"
  identity_sources = each.value.identity_sources
  name             = each.key

  jwt_configuration {
    audience = each.value.audience
    issuer   = coalesce(each.value.issuer, aws_apigatewayv2_api.this.api_endpoint)
  }
}

resource "aws_apigatewayv2_integration" "http" {
  for_each = local.http_routes

  api_id               = aws_apigatewayv2_api.this.id
  integration_type     = "HTTP_PROXY"
  integration_method   = each.value.integration_method
  integration_uri      = each.value.integration_uri
  connection_type      = upper(each.value.connection_type)
  connection_id        = upper(each.value.connection_type) == "VPC_LINK" ? aws_apigatewayv2_vpc_link.this[0].id : null
  timeout_milliseconds = each.value.timeout_milliseconds
  description          = "Backend HTTP da rota ${each.key}"
}

resource "aws_apigatewayv2_route" "http" {
  for_each = local.http_routes

  api_id               = aws_apigatewayv2_api.this.id
  route_key            = each.key
  authorization_type   = each.value.authorization_type
  authorizer_id        = upper(each.value.authorization_type) == "JWT" ? aws_apigatewayv2_authorizer.jwt[each.value.authorizer_key].id : null
  authorization_scopes = upper(each.value.authorization_type) == "JWT" ? each.value.authorization_scopes : []
  target               = "integrations/${aws_apigatewayv2_integration.http[each.key].id}"
}

resource "aws_apigatewayv2_integration" "lambda" {
  for_each = local.lambda_routes

  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = each.value.invoke_arn
  payload_format_version = each.value.payload_format_version
  timeout_milliseconds   = each.value.timeout_milliseconds
  description            = "Backend Lambda da rota ${each.key}"
}

resource "aws_apigatewayv2_route" "lambda" {
  for_each = local.lambda_routes

  api_id               = aws_apigatewayv2_api.this.id
  route_key            = each.key
  authorization_type   = each.value.authorization_type
  authorizer_id        = upper(each.value.authorization_type) == "JWT" ? aws_apigatewayv2_authorizer.jwt[each.value.authorizer_key].id : null
  authorization_scopes = upper(each.value.authorization_type) == "JWT" ? each.value.authorization_scopes : []
  target               = "integrations/${aws_apigatewayv2_integration.lambda[each.key].id}"
}

resource "aws_lambda_permission" "allow_api_gateway" {
  for_each = {
    for route_key, route in local.lambda_routes : route_key => route
    if try(route.function_name, null) != null && trim(route.function_name) != ""
  }

  statement_id  = "AllowExecutionFromApiGateway${substr(md5(each.key), 0, 8)}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = var.stage_name
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = var.default_route_throttling_burst_limit
    throttling_rate_limit  = var.default_route_throttling_rate_limit
  }

  dynamic "access_log_settings" {
    for_each = var.enable_access_logs ? [1] : []

    content {
      destination_arn = aws_cloudwatch_log_group.this[0].arn
      format = jsonencode({
        requestId               = "$context.requestId"
        ip                      = "$context.identity.sourceIp"
        requestTime             = "$context.requestTime"
        httpMethod              = "$context.httpMethod"
        path                    = "$context.path"
        routeKey                = "$context.routeKey"
        status                  = "$context.status"
        protocol                = "$context.protocol"
        responseLength          = "$context.responseLength"
        errorMessage            = "$context.error.message"
        errorResponseType       = "$context.error.responseType"
        authorizerError         = "$context.authorizer.error"
        integrationErrorMessage = "$context.integrationErrorMessage"
      })
    }
  }

  tags = var.tags
}
