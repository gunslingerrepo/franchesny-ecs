terraform {
  backend "s3" {
    bucket       = "franchesny-tfstate-acctid"
    key          = "franchesny/prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}