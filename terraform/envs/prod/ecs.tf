module "ecs_cluster" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 6.0.0"

  cluster_name = "${var.project_name}-ecs-cluster"



  # Cluster capacity providers
  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 100
    }

  }

  tags = var.tags
}