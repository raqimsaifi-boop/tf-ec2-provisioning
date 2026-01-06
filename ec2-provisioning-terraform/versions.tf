terraform {
  requiredversion = ">= 1.5.0"
  requiredproviders {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}