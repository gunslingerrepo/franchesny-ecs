module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-alb-sg"
  description = "Allow inbound HTTPS from internet for the ALB"
  vpc_id      = module.vpc01.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "https-443-tcp"]

  egress_rules = ["all-all"]
}

module "ecs_tasks_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${var.project_name}-ecs-tasks-sg"
  description = "ingress: only from ALB and internal tasks"
  vpc_id      = module.vpc01.vpc_id

  # Ingress from ALB to the frontend service
  ingress_with_source_security_group_id = [
    {
      from_port                = 8080
      to_port                  = 8080
      protocol                 = "tcp"
      description              = "Inbound from ALB to Frontend"
      source_security_group_id = module.alb_sg.security_group_id
    }
  ]

  egress_rules = ["all-all"]
}