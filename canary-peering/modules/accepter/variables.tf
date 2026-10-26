variable "name" {
  description = "Name tag for this account's side of the peering connection, e.g. \"fitbooks-tst-from-network\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$", var.name))
    error_message = "name must be 2 to 64 lowercase letters, digits or '-', starting and ending with a letter or digit."
  }
}

variable "vpc_peering_connection_id" {
  description = "The peering connection to accept: the requester module's vpc_peering_connection_id output."
  type        = string

  validation {
    condition     = can(regex("^pcx-[0-9a-f]{8}([0-9a-f]{9})?$", var.vpc_peering_connection_id))
    error_message = "vpc_peering_connection_id must be a peering connection id (pcx- followed by 8 or 17 hex digits)."
  }
}

variable "vpc_id" {
  description = "This account's (the spoke's) VPC. The connection must target it, or the plan fails."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8}([0-9a-f]{9})?$", var.vpc_id))
    error_message = "vpc_id must be a VPC id (vpc- followed by 8 or 17 hex digits)."
  }
}

variable "requester_owner_id" {
  description = "The account that must own the requesting (hub) VPC. A connection requested from any other account is refused at plan: accepting one opens this VPC to a stranger."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.requester_owner_id))
    error_message = "requester_owner_id must be a 12-digit AWS account id."
  }
}

variable "requester_vpc_id" {
  description = "The VPC that must be the requesting (hub) VPC. Any other is refused at plan."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8}([0-9a-f]{9})?$", var.requester_vpc_id))
    error_message = "requester_vpc_id must be a VPC id (vpc- followed by 8 or 17 hex digits)."
  }
}

variable "tunnel_cidr" {
  description = "The destination of the return route: the hub's WireGuard tunnel subnet (tf-aws-wireguard's peer_cidr, from the ADR-0048 §5 registry, e.g. 100.112.0.0/24). A network address inside the tunnel block 100.112.0.0/12, /20 to /28 -- the same rule as tf-aws-wireguard's peer_cidr. It must not overlap this VPC."
  type        = string

  validation {
    condition = (
      can(cidrnetmask(var.tunnel_cidr))
      && cidrhost(var.tunnel_cidr, 0) == split("/", var.tunnel_cidr)[0]
      && tonumber(split("/", var.tunnel_cidr)[1]) >= 20
      && tonumber(split("/", var.tunnel_cidr)[1]) <= 28
      && cidrhost("${split("/", var.tunnel_cidr)[0]}/12", 0) == "100.112.0.0"
    )
    error_message = "tunnel_cidr must be a network address from the WireGuard tunnel block 100.112.0.0/12 (ADR-0048 §D2), /20 to /28 -- the hub's peer_cidr, e.g. 100.112.0.0/24."
  }
}

variable "route_table_ids" {
  description = "EVERY route table in this VPC whose subnets must answer tunnel peers: each gets tunnel_cidr -> this peering connection. A subnet whose table is left out silently drops every reply to a peer. No duplicates, and known at plan (they key the routes). Empty only with return_routes_deferred = true."
  type        = list(string)

  validation {
    condition     = length(distinct(var.route_table_ids)) == length(var.route_table_ids) && alltrue([for id in var.route_table_ids : can(regex("^rtb-[0-9a-f]{8}([0-9a-f]{9})?$", id))])
    error_message = "route_table_ids must be distinct route table ids (rtb- followed by 8 or 17 hex digits)."
  }
}

variable "return_routes_deferred" {
  description = "true accepts the connection with NO return route (route_table_ids = []): the staged cutover's first apply, while a table still routes tunnel_cidr to an in-VPC hub. Required for an empty route_table_ids, so a forgotten list is a plan error, not a silent outage. Set it back to false when the routes land."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for this account's side of the peering connection (merged under the module's own)."
  type        = map(string)
  default     = {}
}
