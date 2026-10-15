variable "name" {
  description = "Parameter name suffix."
  type        = string
}

variable "value" {
  description = "Parameter value."
  type        = string
}

variable "tags" {
  description = "Tags."
  type        = map(string)
  default     = {}
}
