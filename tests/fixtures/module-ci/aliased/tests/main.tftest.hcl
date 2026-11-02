# The aliased fixture ships a test so tf-module-ci's `terraform test` runs at a
# module root whose validation happens elsewhere (validate_directory). That
# step needs an init AT THE ROOT; with only the validate directory initialised
# it fails "unknown provider" (PROOF on tf-workflows#13).
#
# The test supplies both configurations itself, the default and the alias, as
# a caller would.
provider "null" {}

provider "null" {
  alias = "secondary"
}

run "both_providers_are_used" {
  command = plan

  assert {
    condition     = null_resource.primary != null && null_resource.secondary != null
    error_message = "the module must plan a resource on each provider configuration"
  }
}
