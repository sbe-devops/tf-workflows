mock_provider "aws" {}

variables {
  name  = "probe"
  value = "x"
}

run "renders_the_name" {
  command = plan
  assert {
    condition     = aws_ssm_parameter.canary.name == "/canary/probe"
    error_message = "unexpected parameter name"
  }
}
