# The hub (requester) side of a cross-account VPC peering: the request, and the
# hub-side route to the spoke. The spoke's account accepts with ../accepter and
# adds the return route there (ADR-0031 §11).

data "aws_vpc" "this" {
  id = var.vpc_id
}

locals {
  # Terraform has no CIDR-overlap function, so each CIDR is reduced to (network
  # number, prefix); two overlap iff they agree on the shorter prefix's bits. The
  # same reduction as tf-aws-vpc's address plan and tf-aws-wireguard.
  _hub_cidrs = distinct(concat([data.aws_vpc.this.cidr_block], [for a in data.aws_vpc.this.cidr_block_associations : a.cidr_block]))
  _net = { for c in distinct(concat([var.peer_vpc_cidr], local._hub_cidrs)) : c => {
    n = sum([for i, o in split(".", split("/", c)[0]) : tonumber(o) * pow(256, 3 - i)])
    p = tonumber(split("/", c)[1])
  } }
  overlap_problems = [for c in local._hub_cidrs : "peer_vpc_cidr ${var.peer_vpc_cidr} overlaps the hub VPC's CIDR ${c}" if(
    floor(local._net[var.peer_vpc_cidr].n / pow(2, 32 - min(local._net[var.peer_vpc_cidr].p, local._net[c].p)))
    == floor(local._net[c].n / pow(2, 32 - min(local._net[var.peer_vpc_cidr].p, local._net[c].p)))
  )]

  tags = merge(var.tags, { Name = var.name, "sbe:module" = "tf-aws-vpc-peering/requester" })
}

resource "aws_vpc_peering_connection" "this" {
  vpc_id        = var.vpc_id
  peer_owner_id = var.peer_owner_id
  peer_vpc_id   = var.peer_vpc_id
  peer_region   = var.peer_region

  # Cross-account: only the accepter's account can accept.
  auto_accept = false

  tags = local.tags

  lifecycle {
    precondition {
      condition     = length(local.overlap_problems) == 0
      error_message = join("; ", local.overlap_problems)
    }
  }
}

# Keyed by route table id, not list position, so reordering or adding a table
# never replaces a live route. Until the accepter accepts, AWS keeps these in
# state "blackhole" with no effect (documented); they go live on acceptance.
resource "aws_route" "to_peer" {
  for_each = toset(var.route_table_ids)

  route_table_id            = each.key
  destination_cidr_block    = var.peer_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Once the spoke accepts, AWS reports the accepter VPC's CIDRs on the connection.
# A hub-side route to anything outside them sends hub traffic into a peering
# that can't deliver it: a silent black hole. A check, not a precondition: it
# can't be known before acceptance, and it must not block the apply that
# creates the request. The data source is scoped to the check, so a failed read
# is a warning too.
check "peer_vpc_cidr_inside_accepter_vpc" {
  data "aws_vpc_peering_connection" "after_accept" {
    id = aws_vpc_peering_connection.this.id
  }

  assert {
    condition = length(data.aws_vpc_peering_connection.after_accept.peer_cidr_block_set) == 0 || anytrue([
      for b in data.aws_vpc_peering_connection.after_accept.peer_cidr_block_set : (
        tonumber(split("/", var.peer_vpc_cidr)[1]) >= tonumber(split("/", b.cidr_block)[1])
        && cidrhost("${split("/", var.peer_vpc_cidr)[0]}/${split("/", b.cidr_block)[1]}", 0) == split("/", b.cidr_block)[0]
      )
    ])
    error_message = "peer_vpc_cidr ${var.peer_vpc_cidr} is not inside the accepter VPC's CIDRs (${join(", ", [for b in data.aws_vpc_peering_connection.after_accept.peer_cidr_block_set : b.cidr_block])}): the hub-side route goes nowhere."
  }
}
