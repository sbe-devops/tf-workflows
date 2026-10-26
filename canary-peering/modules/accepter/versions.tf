terraform {
  required_version = "~> 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.8.0, < 7.0.0"
    }
  }
}
