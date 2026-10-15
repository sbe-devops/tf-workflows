# CANARY FIXTURE (branch canary/ubuntu-26-04 only, never merged): a minimal module
# shaped like a tf-aws-* one, so tf-module-ci exercises the AWS provider download,
# tflint, checkov, validate and a mocked terraform test on the Ubuntu 26.04 image.
resource "aws_ssm_parameter" "canary" {
  name  = "/canary/${var.name}"
  type  = "String"
  value = var.value
  tags  = var.tags
}
