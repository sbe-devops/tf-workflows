output "vpc_peering_connection_id" {
  description = "The accepted peering connection id."
  value       = aws_vpc_peering_connection_accepter.this.vpc_peering_connection_id
}

output "accept_status" {
  description = "The connection's status after acceptance (\"active\" once AWS finishes provisioning)."
  value       = aws_vpc_peering_connection_accepter.this.accept_status
}

output "requester_vpc_cidr" {
  description = "The requester (hub) VPC's primary CIDR, as the connection reports it."
  value       = data.aws_vpc_peering_connection.this.cidr_block
}

output "route_ids" {
  description = "The return routes, by route table id."
  value       = { for k, r in aws_route.return : k => r.id }
}
