output "load_balancer_arn" {
  value = aws_lb.this.arn
}

output "load_balancer_dns_name" {
  value = aws_lb.this.dns_name
}

output "listener_arn" {
  value = aws_lb_listener.this.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.this.arn
}

output "security_group_id" {
  value = aws_security_group.this.id
}
