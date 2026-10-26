variable "name" {
  description = "Name tag for the peering connection, e.g. \"fitbooks-network-to-tst\". Tags apply only in the account that creates them, so the accepter tags its side separately."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$", var.name))
    error_message = "name must be 2 to 64 lowercase letters, digits or '-', starting and ending with a letter or digit."
  }
}

variable "vpc_id" {
  description = "The requester (hub) VPC, in this provider's account. Its CIDRs are read, not passed in, so the overlap check sees a secondary CIDR added later."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8}([0-9a-f]{9})?$", var.vpc_id))
    error_message = "vpc_id must be a VPC id (vpc- followed by 8 or 17 hex digits)."
  }
}

variable "peer_owner_id" {
  description = "The 12-digit account id that owns the accepter (spoke) VPC."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.peer_owner_id))
    error_message = "peer_owner_id must be a 12-digit AWS account id."
  }
}

variable "peer_vpc_id" {
  description = "The accepter (spoke) VPC, in peer_owner_id's account."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8}([0-9a-f]{9})?$", var.peer_vpc_id))
    error_message = "peer_vpc_id must be a VPC id (vpc- followed by 8 or 17 hex digits)."
  }
}

variable "peer_region" {
  description = "The accepter VPC's region, for an inter-Region peering. null (the default) means this provider's region."
  type        = string
  default     = null

  validation {
    condition     = var.peer_region == null || can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", var.peer_region))
    error_message = "peer_region must be null or an AWS region name such as us-east-1."
  }
}

variable "peer_vpc_cidr" {
  description = "The destination of the hub-side route: the spoke VPC's CIDR, or the portion of it the hub may reach. A private (RFC 1918) network address, /16 to /28 -- never a default route, never the tunnel block. It must not overlap the hub VPC."
  type        = string

  validation {
    condition = (
      can(cidrnetmask(var.peer_vpc_cidr))
      && cidrhost(var.peer_vpc_cidr, 0) == split("/", var.peer_vpc_cidr)[0]
      && tonumber(split("/", var.peer_vpc_cidr)[1]) >= 16
      && tonumber(split("/", var.peer_vpc_cidr)[1]) <= 28
      && anytrue([
        cidrhost("${split("/", var.peer_vpc_cidr)[0]}/8", 0) == "10.0.0.0",
        cidrhost("${split("/", var.peer_vpc_cidr)[0]}/12", 0) == "172.16.0.0",
        cidrhost("${split("/", var.peer_vpc_cidr)[0]}/16", 0) == "192.168.0.0",
      ])
    )
    error_message = "peer_vpc_cidr must be an RFC 1918 network address (inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16), /16 to /28 -- e.g. 10.0.0.0/16."
  }
}

variable "route_table_ids" {
  description = "Every hub VPC route table that gets the route peer_vpc_cidr -> this peering connection: the tables of the subnets the hub runs in. At least one, no duplicates, and known at plan (they key the routes)."
  type        = list(string)

  validation {
    condition     = length(var.route_table_ids) > 0 && length(distinct(var.route_table_ids)) == length(var.route_table_ids) && alltrue([for id in var.route_table_ids : can(regex("^rtb-[0-9a-f]{8}([0-9a-f]{9})?$", id))])
    error_message = "route_table_ids must be one or more distinct route table ids (rtb- followed by 8 or 17 hex digits)."
  }
}

variable "tags" {
  description = "Tags for the peering connection (merged under the module's own)."
  type        = map(string)
  default     = {}
}
