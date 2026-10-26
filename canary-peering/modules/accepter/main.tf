# The spoke (accepter) side of a cross-account VPC peering: accept the hub's
# request, and add the RETURN route to the hub's tunnel subnet in every route
# table passed (ADR-0031 §11: return routes live in each peered VPC's own stack).

data "aws_caller_identity" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# Read before accepting, so the checks below see who is asking and for what.
data "aws_vpc_peering_connection" "this" {
  id = var.vpc_peering_connection_id
}

locals {
  # The connection must be exactly the one the caller declared: from the
  # declared account and VPC, into this account and this VPC.
  connection_problems = compact([
    data.aws_vpc_peering_connection.this.owner_id == var.requester_owner_id ? "" : "the connection was requested by account ${data.aws_vpc_peering_connection.this.owner_id}, not requester_owner_id ${var.requester_owner_id}",
    data.aws_vpc_peering_connection.this.vpc_id == var.requester_vpc_id ? "" : "the connection was requested from ${data.aws_vpc_peering_connection.this.vpc_id}, not requester_vpc_id ${var.requester_vpc_id}",
    data.aws_vpc_peering_connection.this.peer_owner_id == data.aws_caller_identity.current.account_id ? "" : "the connection targets account ${data.aws_vpc_peering_connection.this.peer_owner_id}, not this provider's account ${data.aws_caller_identity.current.account_id}",
    data.aws_vpc_peering_connection.this.peer_vpc_id == var.vpc_id ? "" : "the connection targets ${data.aws_vpc_peering_connection.this.peer_vpc_id}, not vpc_id ${var.vpc_id}",
  ])

  # Terraform has no CIDR-overlap function, so each CIDR is reduced to (network
  # number, prefix); two overlap iff they agree on the shorter prefix's bits. The
  # same reduction as tf-aws-vpc's address plan and tf-aws-wireguard.
  _vpc_cidrs = distinct(concat([data.aws_vpc.this.cidr_block], [for a in data.aws_vpc.this.cidr_block_associations : a.cidr_block]))
  _net = { for c in distinct(concat([var.tunnel_cidr], local._vpc_cidrs)) : c => {
    n = sum([for i, o in split(".", split("/", c)[0]) : tonumber(o) * pow(256, 3 - i)])
    p = tonumber(split("/", c)[1])
  } }
  overlap_problems = [for c in local._vpc_cidrs : "tunnel_cidr ${var.tunnel_cidr} overlaps this VPC's CIDR ${c}" if(
    floor(local._net[var.tunnel_cidr].n / pow(2, 32 - min(local._net[var.tunnel_cidr].p, local._net[c].p)))
    == floor(local._net[c].n / pow(2, 32 - min(local._net[var.tunnel_cidr].p, local._net[c].p)))
  )]

  tags = merge(var.tags, { Name = var.name, "sbe:module" = "tf-aws-vpc-peering/accepter" })
}

resource "aws_vpc_peering_connection_accepter" "this" {
  vpc_peering_connection_id = var.vpc_peering_connection_id
  auto_accept               = true

  tags = local.tags

  lifecycle {
    precondition {
      condition     = length(local.connection_problems) == 0
      error_message = join("; ", local.connection_problems)
    }
    precondition {
      condition     = length(local.overlap_problems) == 0
      error_message = join("; ", local.overlap_problems)
    }
    precondition {
      condition     = (length(var.route_table_ids) == 0) == var.return_routes_deferred
      error_message = var.return_routes_deferred ? "return_routes_deferred = true but route_table_ids is not empty: set it back to false now that the routes are passed." : "route_table_ids is empty: with no return route, every reply to a tunnel peer is dropped. Pass the tables, or set return_routes_deferred = true for the staged cutover's first apply."
    }
  }
}

# The return route. Keyed by route table id, not list position, so reordering
# or adding a table never replaces a live route.
#
# 🔑 IMPORTABLE OVER AN EXISTING ROUTE. A table that already routes tunnel_cidr
# somewhere else (an in-VPC hub's ENI) can't take a second route to the same
# destination. Import it instead -- id "<rtb-id>_<tunnel_cidr>" -- and the plan
# retargets it in place (~ update, one ReplaceRoute): vpc_peering_connection_id
# is not ForceNew, and the provider's update sends the one target that changed.
# A "-/+ replace" in that plan is a STOP: it means delete-then-create, an outage.
resource "aws_route" "return" {
  for_each = toset(var.route_table_ids)

  route_table_id            = each.key
  destination_cidr_block    = var.tunnel_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.vpc_peering_connection_id
}
