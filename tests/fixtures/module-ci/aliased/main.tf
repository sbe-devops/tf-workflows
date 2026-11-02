# A module that needs an ALIASED provider from its caller, as tf-aws-static-site
# needs aws.us_east_1 for its CloudFront certificate. `terraform validate` at
# this root fails ("Provider configuration not present"): only a caller can
# supply null.secondary. examples/basic is that caller.
terraform {
  required_version = ">= 1.7"

  required_providers {
    null = {
      source                = "hashicorp/null"
      version               = ">= 3.0"
      configuration_aliases = [null.secondary]
    }
  }
}

resource "null_resource" "primary" {}

resource "null_resource" "secondary" {
  provider = null.secondary
}
