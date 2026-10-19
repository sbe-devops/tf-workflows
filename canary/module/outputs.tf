output "parameter_name" {
  description = "The parameter's name."
  value       = aws_ssm_parameter.canary.name
}
