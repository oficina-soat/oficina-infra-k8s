resource "aws_ecr_repository" "app" {
  count                = var.create_repository ? 1 : 0
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = var.repository_name
  }
}

data "aws_ecr_repository" "app" {
  count = var.create_repository ? 0 : 1
  name  = var.repository_name
}

locals {
  resolved_repository_name = var.create_repository ? aws_ecr_repository.app[0].name : data.aws_ecr_repository.app[0].name
  resolved_repository_url  = var.create_repository ? aws_ecr_repository.app[0].repository_url : data.aws_ecr_repository.app[0].repository_url
}
