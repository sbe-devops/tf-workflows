# The accepter: the rendered plan, offline (mock provider). Literal values are
# Fitbooks tst's real ids and ranges (measured 2026-10-26): VPC
# vpc-097c21f88c906157b 10.0.0.0/16, public table rtb-0350fc56befc9fd86, main
# table rtb-014efb7f94a46c42e, tunnel 100.112.0.0/24. The requester ids are
# stand-ins (the network account's VPC doesn't exist yet).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_vpc" {
    defaults = {
      cidr_block              = "10.0.0.0/16"
      cidr_block_associations = [{ association_id = "vpc-cidr-assoc-0", cidr_block = "10.0.0.0/16", state = "associated" }]
    }
  }
  mock_data "aws_vpc_peering_connection" {
    defaults = {
      owner_id      = "222222222222"
      vpc_id        = "vpc-0aaaaaaaaaaaaaaaa"
      peer_owner_id = "111111111111"
      peer_vpc_id   = "vpc-097c21f88c906157b"
      cidr_block    = "10.128.0.0/20"
    }
  }
}

variables {
  name                      = "fitbooks-tst-from-network"
  vpc_peering_connection_id = "pcx-0123456789abcdef0"
  vpc_id                    = "vpc-097c21f88c906157b"
  requester_owner_id        = "222222222222"
  requester_vpc_id          = "vpc-0aaaaaaaaaaaaaaaa"
  tunnel_cidr               = "100.112.0.0/24"
  route_table_ids           = ["rtb-0350fc56befc9fd86"]
}

# ── Accepted ────────────────────────────────────────────────────────────────

run "fitbooks_tst_return_route" {
  command = plan

  assert {
    condition     = aws_vpc_peering_connection_accepter.this.vpc_peering_connection_id == "pcx-0123456789abcdef0" && aws_vpc_peering_connection_accepter.this.auto_accept == true
    error_message = "The accepter must accept exactly the declared connection."
  }

  # Derived intent, both directions: the routes are EXACTLY one per table passed,
  # to tunnel_cidr, via this connection -- no more tables, no fewer, no other
  # destination, no other target.
  assert {
    condition = (
      toset(keys(aws_route.return)) == toset(var.route_table_ids)
      && toset([for k, r in aws_route.return : "${r.route_table_id}|${r.destination_cidr_block}|${r.vpc_peering_connection_id}"])
      == toset([for t in var.route_table_ids : "${t}|${var.tunnel_cidr}|${var.vpc_peering_connection_id}"])
    )
    error_message = "The return routes must be exactly tunnel_cidr -> the connection, in exactly the tables passed."
  }

  assert {
    condition = alltrue([for r in values(aws_route.return) : (
      r.gateway_id == null && r.nat_gateway_id == null && r.transit_gateway_id == null
      && r.vpc_endpoint_id == null && r.egress_only_gateway_id == null && r.carrier_gateway_id == null
      && r.local_gateway_id == null && r.core_network_arn == null
      && r.destination_ipv6_cidr_block == null && r.destination_prefix_list_id == null
    )])
    error_message = "A return route may have no target but the peering connection, and no destination but tunnel_cidr."
  }

  # The cutover imports tst's existing route at exactly this address; the id is
  # "<rtb>_<tunnel_cidr>". The key must be the table id, never a list index.
  assert {
    condition     = aws_route.return["rtb-0350fc56befc9fd86"].route_table_id == "rtb-0350fc56befc9fd86"
    error_message = "The return route must be keyed by its route table id (the import address)."
  }

  assert {
    condition     = aws_vpc_peering_connection_accepter.this.tags == tomap({ Name = "fitbooks-tst-from-network", "sbe:module" = "tf-aws-vpc-peering/accepter" })
    error_message = "Tags must be Name plus the module tag."
  }
}

run "public_and_main_tables" {
  command = plan

  variables {
    route_table_ids = ["rtb-0350fc56befc9fd86", "rtb-014efb7f94a46c42e"]
  }

  assert {
    condition = toset([for k, r in aws_route.return : "${r.route_table_id}|${r.destination_cidr_block}|${r.vpc_peering_connection_id}"]) == toset([
      "rtb-0350fc56befc9fd86|100.112.0.0/24|pcx-0123456789abcdef0",
      "rtb-014efb7f94a46c42e|100.112.0.0/24|pcx-0123456789abcdef0",
    ])
    error_message = "Every table passed gets the return route (literal expected set)."
  }
}

run "staged_cutover_accepts_with_no_route" {
  command = plan

  variables {
    route_table_ids        = []
    return_routes_deferred = true
  }

  assert {
    condition     = length(aws_route.return) == 0 && aws_vpc_peering_connection_accepter.this.auto_accept == true
    error_message = "Deferred: accept, and create no route."
  }
}

run "long_ids_and_a_small_tunnel" {
  command = plan

  variables {
    tunnel_cidr     = "100.127.255.240/28"
    route_table_ids = ["rtb-0a1b2c3d"]
  }

  assert {
    condition     = aws_route.return["rtb-0a1b2c3d"].destination_cidr_block == "100.127.255.240/28"
    error_message = "The last /28 of the tunnel block is accepted."
  }
}

# ── Refused: the tunnel CIDR ────────────────────────────────────────────────

run "refuses_a_default_route" {
  command = plan
  variables { tunnel_cidr = "0.0.0.0/0" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_the_old_in_vpc_range" {
  command = plan
  variables { tunnel_cidr = "10.8.0.0/24" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_cgnat_outside_the_tunnel_block" {
  command = plan
  variables { tunnel_cidr = "100.64.0.0/24" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_just_past_the_tunnel_block" {
  command = plan
  variables { tunnel_cidr = "100.128.0.0/24" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_the_whole_tunnel_block" {
  command = plan
  variables { tunnel_cidr = "100.112.0.0/12" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_a_host_address" {
  command = plan
  variables { tunnel_cidr = "100.112.0.1/24" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_a_host_route" {
  command = plan
  variables { tunnel_cidr = "100.112.0.1/32" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_ipv6" {
  command = plan
  variables { tunnel_cidr = "fd00::/64" }
  expect_failures = [var.tunnel_cidr]
}

run "refuses_tunnel_overlapping_this_vpc" {
  command = plan

  override_data {
    target = data.aws_vpc.this
    values = {
      cidr_block = "10.0.0.0/16"
      cidr_block_associations = [
        { association_id = "vpc-cidr-assoc-0", cidr_block = "10.0.0.0/16", state = "associated" },
        { association_id = "vpc-cidr-assoc-1", cidr_block = "100.112.0.0/22", state = "associated" },
      ]
    }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

# ── Refused: the route tables ───────────────────────────────────────────────

run "refuses_a_duplicate_table" {
  command = plan
  variables { route_table_ids = ["rtb-0350fc56befc9fd86", "rtb-0350fc56befc9fd86"] }
  expect_failures = [var.route_table_ids]
}

run "refuses_a_non_table_id" {
  command = plan
  variables { route_table_ids = ["eni-032ee1e5ef55b3e89"] }
  expect_failures = [var.route_table_ids]
}

run "refuses_no_tables_unless_deferred" {
  command = plan
  variables { route_table_ids = [] }
  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

run "refuses_deferred_with_tables" {
  command = plan
  variables { return_routes_deferred = true }
  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

# ── Refused: the wrong connection ───────────────────────────────────────────

run "refuses_a_request_from_another_account" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.this
    values = { owner_id = "333333333333", vpc_id = "vpc-0aaaaaaaaaaaaaaaa", peer_owner_id = "111111111111", peer_vpc_id = "vpc-097c21f88c906157b" }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

run "refuses_a_request_from_another_vpc" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.this
    values = { owner_id = "222222222222", vpc_id = "vpc-0bbbbbbbbbbbbbbbb", peer_owner_id = "111111111111", peer_vpc_id = "vpc-097c21f88c906157b" }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

run "refuses_a_connection_into_another_vpc" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.this
    values = { owner_id = "222222222222", vpc_id = "vpc-0aaaaaaaaaaaaaaaa", peer_owner_id = "111111111111", peer_vpc_id = "vpc-0ccccccccccccccccc" }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

run "refuses_a_connection_into_another_account" {
  command = plan

  override_data {
    target = data.aws_vpc_peering_connection.this
    values = { owner_id = "222222222222", vpc_id = "vpc-0aaaaaaaaaaaaaaaa", peer_owner_id = "444444444444", peer_vpc_id = "vpc-097c21f88c906157b" }
  }

  expect_failures = [aws_vpc_peering_connection_accepter.this]
}

# ── Refused: malformed ids ──────────────────────────────────────────────────

run "refuses_a_malformed_connection_id" {
  command = plan
  variables { vpc_peering_connection_id = "pcx-*" }
  expect_failures = [var.vpc_peering_connection_id]
}

run "refuses_a_malformed_requester_account" {
  command = plan
  variables { requester_owner_id = "22222222222" }
  expect_failures = [var.requester_owner_id]
}
