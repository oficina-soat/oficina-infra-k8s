output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  value     = aws_eks_cluster.this.certificate_authority[0].data
  sensitive = true
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_autoscaling_group_names" {
  value = [
    for autoscaling_group in aws_eks_node_group.this.resources[0].autoscaling_groups :
    autoscaling_group["name"]
  ]
}

output "node_group_autoscaling_group_name" {
  value = aws_eks_node_group.this.resources[0].autoscaling_groups[0]["name"]
}
