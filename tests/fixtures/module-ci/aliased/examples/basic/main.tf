terraform {
  required_version = ">= 1.7"

  required_providers {
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0"
    }
  }
}

provider "null" {}

provider "null" {
  alias = "secondary"
}

module "this" {
  source = "../.."

  providers = {
    null           = null
    null.secondary = null.secondary
  }
}
