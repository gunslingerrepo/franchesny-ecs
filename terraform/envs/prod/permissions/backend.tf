terraform {
  backend "s3" {
    bucket       = "permission-tfstate-716542960555"
    key          = "franchesny/permissions/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}