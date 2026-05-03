resource "aws_ecr_repository" "app" {
  name                 = var.repository_name
  force_delete         = var.force_delete
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

moved {
  from = aws_ecr_repository.app[0]
  to   = aws_ecr_repository.app
}
