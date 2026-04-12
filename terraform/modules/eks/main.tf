data "aws_caller_identity" "current" {}

locals {
  caller_arn = data.aws_caller_identity.current.arn

  # Quando a identidade atual e STS assumed-role, o ARN vem como:
  # arn:aws:sts::<acct>:assumed-role/<role-name>/<session-name>
  #
  # Para EKS Access Entry, precisamos do ARN IAM da role:
  # arn:aws:iam::<acct>:role/<role-name>
  #
  # Evitamos `data aws_iam_session_context` porque alguns ambientes de
  # laboratorio negam `iam:GetRole`.
  assumed_role_match  = regexall("^arn:aws:sts::[0-9]+:assumed-role/([^/]+)/", local.caller_arn)
  assumed_role_name   = length(local.assumed_role_match) > 0 ? local.assumed_role_match[0][0] : null
  caller_iam_role_arn = local.assumed_role_name != null ? "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.assumed_role_name}" : null
  effective_access_principal_arn = coalesce(
    var.access_principal_arn,
    local.caller_iam_role_arn,
    local.caller_arn,
  )
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = false
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  tags = {
    Name = var.cluster_name
  }
}

resource "aws_eks_access_entry" "this" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = local.effective_access_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  capacity_type   = var.node_capacity_type
  instance_types  = [var.instance_type]
  ami_type        = var.node_ami_type

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  tags = {
    Name = "${var.cluster_name}-ng"
  }
}
