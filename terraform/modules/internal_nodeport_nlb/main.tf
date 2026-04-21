locals {
  allowed_source_security_group_ids_by_index = {
    for index, security_group_id in var.allowed_source_security_group_ids : tostring(index) => security_group_id
  }
  target_security_group_ids_by_index = {
    for index, security_group_id in var.target_security_group_ids : tostring(index) => security_group_id
  }
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-nlb-"
  description = "Security group do NLB interno ${var.name}"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name}-nlb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "from_sources" {
  for_each = local.allowed_source_security_group_ids_by_index

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.listener_port
  to_port                      = var.listener_port

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "to_targets" {
  for_each = local.target_security_group_ids_by_index

  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.target_node_port
  to_port                      = var.target_node_port

  tags = var.tags
}

resource "aws_lb" "this" {
  name                             = var.name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  security_groups                  = [aws_security_group.this.id]
  enable_cross_zone_load_balancing = true

  tags = merge(var.tags, {
    Name = var.name
  })
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name}-tg"
  port        = var.target_node_port
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled  = true
    protocol = "TCP"
    port     = "traffic-port"
  }

  tags = merge(var.tags, {
    Name = "${var.name}-tg"
  })
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = var.tags
}

resource "aws_autoscaling_attachment" "this" {
  autoscaling_group_name = var.target_autoscaling_group_name
  lb_target_group_arn    = aws_lb_target_group.this.arn
}

resource "aws_vpc_security_group_ingress_rule" "targets_from_nlb" {
  for_each = local.target_security_group_ids_by_index

  security_group_id            = each.value
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = var.target_node_port
  to_port                      = var.target_node_port

  tags = var.tags
}
