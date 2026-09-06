module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 10.0.0"

  name   = "${var.project_name}-alb"
  vpc_id = module.vpc01.vpc_id


  internal = false
  #subnets            = module.vpc.public_subnets
  subnets = module.vpc01.public_subnets

  load_balancer_type = "application"

  security_groups = [module.alb_sg.security_group_id]

  enable_deletion_protection = false


  target_groups = {
    pulsesvc_tg = {
      name_prefix = "ps-"
      protocol    = "HTTP"
      port        = 8080
      target_type = "ip"

      health_check = {
        enabled             = true
        path                = "/health"
        port                = "8080"
        matcher             = "200"
        interval            = 30
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 6
      }
      create_attachment = false
    }
  }


  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"
      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    # Terminate TLS, forward to the Fargate task.
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = aws_acm_certificate.alb.arn # self-signed, not module.acm

      forward = {
        target_group_key = "pulsesvc_tg"
      }
    }
  }

  tags = var.tags
}

output "alb_dns_name" {
  description = "The public DNS name of the load balancer"
  value       = module.alb.dns_name
}