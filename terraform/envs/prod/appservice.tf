module "pulsesvc_service" {
  source  = "terraform-aws-modules/ecs/aws//modules/service"
  version = "~> 6.0.0"

  name        = "pulseservice"
  cluster_arn = module.ecs_cl8.cluster_arn

  cpu    = 256
  memory = 512
  # shell access without ssh keys
  enable_execute_command = true


  # attach iam role created in iam.tf file
  create_tasks_iam_role = false
  tasks_iam_role_arn    = aws_iam_role.ecs_task_role.arn

  create_task_exec_iam_role = false
  task_exec_iam_role_arn    = aws_iam_role.ecs_task_execution_role.arn

  #Disable Auto Scaling
  enable_autoscaling       = false
  autoscaling_min_capacity = 0
  autoscaling_max_capacity = 0

  # Container definition(s)
  container_definitions = {

    pulsesvc = {
      essential = true
      image     = "${module.ecr.repository_url}:${var.image_tag}"
      portMappings = [
        {
          name          = "pulse"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      # Example image used requires access to write to root filesystem
      readonlyRootFilesystem = true

      environment = [
        { name = "APP_ENV", value = var.environment }
      ]

    },
  }


  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["pulsesvc_tg"].arn
      container_name   = "pulsesvc"
      container_port   = 8080
    }
  }

  # Deploy into private subnets
  subnet_ids         = module.vpc01.private_subnets
  security_group_ids = [module.ecs_tasks_sg.security_group_id]
}