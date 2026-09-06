variable "aws_region" {
  description = "this is aws region to deploy"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "The name of the project"
  type        = string
  default     = "franchesny"
}

variable "environment" {
  description = "The environment to deploy to"
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default = {
    Project     = "franchesny-ecs-AWS"
    Environment = "Production"
    ManagedBy   = "Terraform"
  }
}