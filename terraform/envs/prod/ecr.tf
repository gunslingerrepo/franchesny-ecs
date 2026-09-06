module "ecr" {
  source  = "terraform-aws-modules/ecr/aws"
  version = "~> 3.0.0"

  # Create repos like online-boutique/frontend
  repository_name = "${var.project_name}/pulseservice"

  # Gh Actions to push updated SHA tags over the existing ref if needed
  repository_image_tag_mutability = "MUTABLE"

  #ecr vuln scanner
  repository_image_scan_on_push = true
  repository_force_delete       = true


  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 2
        description  = "Expire untagged images after 2 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 2
        }
        action = { type = "expire" }
      }
    ]
  })

  tags = var.tags

}