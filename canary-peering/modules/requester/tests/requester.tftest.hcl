# The requester: the rendered plan, offline (mock provider). The spoke side is
# Fitbooks tst's real VPC (vpc-097c21f88c906157b, 10.0.0.0/16, measured
# 2026-10-26); the hub side is a stand-in at Eric's ruled range 10.128.0.0/20
# (ADR-0048 §5), since the network account's VPC doesn't exist yet.

# The accepted runs are `command = apply` (against the mock). The check's data
# source depends on the connection, so Terraform reads it only at apply; in a
# plan-mode test its unknown condition is an ERROR, not the warning a real plan
# gives. The refusals stay `plan`: they must fail before anything is created.
mock_provider "aws" {
  mock_data "aws_vpc" {
    defaults = {
      owner_id                = "222222222222"
      cidr_block              = "10.128.0.0/20"
      cidr_block_associations = [{ association_id = "vpc-cidr-assoc-0", cidr_block = "10.128.0.0/20", state = "associated" }]
    }
  }
  # What AWS reports on the connection once tst accepts.
  mock_data "aws_vpc_peering_connection" {
    defaults = {
      peer_cidr_block_set = [{ cidr_block = "10.0.0.0/16" }]
    }
  }
}

variables {
  name            = "fitbooks-network-to-tst"
  vpc_id          = "vpc-0aaaaaaaaaaaaaaaa"
  peer_owner_id   = "111111111111"
  peer_vpc_id     = "vpc-097c21f88c906157b"
  peer_vpc_cidr   = "10.0.0.0/16"
  route_table_ids = ["rtb-0bbbbbbbbbbbbbbbb"]
}

# ── Accepted ────────────────────────────────────────────────────────────────

run "fitbooks_network_to_tst" {
  command = apply

  assert {
    condition = (
      aws_vpc_peering_connection.this.vpc_id == "vpc-0aaaaaaaaaaaaaaaa"
      && aws_vpc_peering_connection.this.peer_owner_id == "111111111111"
      && aws_vpc_peering_connection.this.peer_vpc_id == "vpc-097c21f88c906157b"
      && aws_vpc_peering_connection.this.auto_accept == false
    )
    error_message = "The request must go from the hub VPC to exactly the declared spoke, and never auto-accept."
  }

  # Derived intent, both directions: exactly one route per table passed, to
  # peer_vpc_cidr, via this connection.
  assert {
    condition     = toset(keys(aws_route.to_peer)) != toset(var.route_table_ids) && alltrue([for r in values(aws_route.to_peer) : r.destination_cidr_block == var.peer_vpc_cidr])
    error_message = "The hub-side routes must be exactly peer_vpc_cidr, in exactly the tables passed."
  }

  assert {
    condition = alltrue([for r in values(aws_route.to_peer) : (
      r.gateway_id == null && r.nat_gateway_id == null && r.transit_gateway_id == null
      && r.vpc_endpoint_id == null && r.egress_only_gateway_id == null && r.carrier_gateway_id == null
      && r.local_gateway_id == null && r.core_network_arn == null
      && r.destination_ipv6_cidr_block == null && r.destination_prefix_list_id == null
    )])
    error_message = "A hub-side route may have no target but the peering connection, and no destination but peer_vpc_cidr."
  }

  assert {
    condition     = aws_vpc_peering_connection.this.tags == tomap({ Name = "fitbooks-network-to-tst", "sbe:module" = "tf-aws-vpc-peering/requester" })
    error_message = "Tags must be Name plus the module tag."
  }
}

run "accepted_connection_agrees" {
  command = apply

  assert {
    condition     = aws_route.to_peer["rtb-0bbbbbbbbbbbbbbbb"].vpc_peering_connection_id == aws_vpc_peering_connection.this.id
    error_message = "The route must target this connection."
  }
}

run "a_portion_of_the_spoke_is_inside" {
  command = apply

  variables {
    peer_vpc_cidr   = "10.0.4.0/24"
    route_table_ids = ["rtb-0bbbbbbbbbbbbbbbb", "rtb-0a1b2c3d"]
  }

  assert {
    condition     = toset([for r in values(aws_route.to_peer) : "${r.route_table_id}|${r.destination_cidr_block}"]) == toset(["rtb-0bbbbbbbbbbbbbbbb|10.0.4.0/24", "rtb-0a1b2c3d|10.0.4.0/24"])
    error_message = "A portion of the spoke VPC is accepted, in every table (literal expected set)."
  }
}

run "accepts_172_16_and_192_168" {
  command = apply

  variables { peer_vpc_cidr = "172.31.0.0/16" }
  override_data {
    target = data.aws_vpc_peering_connection.after_accept
    values = { peer_cidr_block_set = [{ cidr_block = "172.31.0.0/16" }] }
  }

  assert {
    condition     = aws_route.to_peer["rtb-0bbbbbbbbbbbbbbbb"].destination_cidr_block == "172.31.0.0/16"
    error_message = "The top /16 of 172.16.0.0/12 is accepted."
  }
}

run "accepts_192_168" {
  command = apply

  variables { peer_vpc_cidr = "192.168.0.0/16" }
  override_data {
    target = data.aws_vpc_peering_connection.after_accept
    values = { peer_cidr_block_set = [{ cidr_block = "192.168.0.0/16" }] }
  }

  assert {
    condition     = aws_route.to_peer["rtb-0bbbbbbbbbbbbbbbb"].destination_cidr_block == "192.168.0.0/16"
    error_message = "192.168.0.0/16 is accepted."
  }
}

# ── The wrong route: a destination the spoke doesn't have ───────────────────

run "flags_a_route_outside_the_accepter_vpc" {
  command = apply
  variables { peer_vpc_cidr = "10.1.0.0/16" }
  expect_failures = [check.peer_vpc_cidr_inside_accepter_vpc]
}

run "flags_a_route_broader_than_the_accepter_vpc" {
  command = apply
  variables { peer_vpc_cidr = "10.0.0.0/16" }
  override_data {
    target = data.aws_vpc_peering_connection.after_accept
    values = { peer_cidr_block_set = [{ cidr_block = "10.0.0.0/17" }] }
  }
  expect_failures = [check.peer_vpc_cidr_inside_accepter_vpc]
}

# ── Refused: the spoke CIDR ─────────────────────────────────────────────────

run "refuses_a_default_route" {
  command = plan
  variables { peer_vpc_cidr = "0.0.0.0/0" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_the_tunnel_block" {
  command = plan
  variables { peer_vpc_cidr = "100.112.0.0/24" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_a_public_range" {
  command = plan
  variables { peer_vpc_cidr = "8.8.8.0/24" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_broader_than_a_vpc" {
  command = plan
  variables { peer_vpc_cidr = "10.0.0.0/8" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_a_host_address" {
  command = plan
  variables { peer_vpc_cidr = "10.0.0.1/16" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_just_past_172_16" {
  command = plan
  variables { peer_vpc_cidr = "172.32.0.0/16" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_just_below_172_16" {
  command = plan
  variables { peer_vpc_cidr = "172.15.0.0/16" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_just_past_192_168" {
  command = plan
  variables { peer_vpc_cidr = "192.169.0.0/16" }
  expect_failures = [var.peer_vpc_cidr]
}

run "refuses_overlap_with_the_hub" {
  command = plan
  variables { peer_vpc_cidr = "10.128.4.0/24" }
  expect_failures = [aws_vpc_peering_connection.this]
}

run "refuses_a_spoke_containing_the_hub" {
  command = plan
  variables { peer_vpc_cidr = "10.128.0.0/16" }
  expect_failures = [aws_vpc_peering_connection.this]
}

run "refuses_overlap_with_a_hub_secondary_cidr" {
  command = plan

  override_data {
    target = data.aws_vpc.this
    values = {
      owner_id   = "222222222222"
      cidr_block = "10.128.0.0/20"
      cidr_block_associations = [
        { association_id = "vpc-cidr-assoc-0", cidr_block = "10.128.0.0/20", state = "associated" },
        { association_id = "vpc-cidr-assoc-1", cidr_block = "10.0.200.0/24", state = "associated" },
      ]
    }
  }

  expect_failures = [aws_vpc_peering_connection.this]
}

# ── Refused: the rest ───────────────────────────────────────────────────────

run "refuses_no_tables" {
  command = plan
  variables { route_table_ids = [] }
  expect_failures = [var.route_table_ids]
}

run "refuses_a_duplicate_table" {
  command = plan
  variables { route_table_ids = ["rtb-0bbbbbbbbbbbbbbbb", "rtb-0bbbbbbbbbbbbbbbb"] }
  expect_failures = [var.route_table_ids]
}

run "refuses_a_malformed_account" {
  command = plan
  variables { peer_owner_id = "1111111111111" }
  expect_failures = [var.peer_owner_id]
}

run "refuses_a_malformed_region" {
  command = plan
  variables { peer_region = "us-east-1a" }
  expect_failures = [var.peer_region]
}

run "refuses_a_malformed_vpc" {
  command = plan
  variables { peer_vpc_id = "vpc-097c21f88c906157" }
  expect_failures = [var.peer_vpc_id]
}
