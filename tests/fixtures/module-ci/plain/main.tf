# A module with no provider alias: the shape 18 of the 19 tf-aws-* modules have.
# Validated at its root, as before validate_directory existed.
terraform {
  required_version = ">= 1.7"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

resource "null_resource" "this" {}
