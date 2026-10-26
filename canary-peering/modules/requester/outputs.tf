output "vpc_peering_connection_id" {
  description = "The peering connection id (pcx-...). Pass it to the accepter in the spoke's account."
  value       = aws_vpc_peering_connection.this.id
}

output "requester_owner_id" {
  description = "The requester's account id, for the accepter's requester_owner_id check."
  value       = data.aws_vpc.this.owner_id
}

output "requester_vpc_id" {
  description = "The requester (hub) VPC id, for the accepter's requester_vpc_id check."
  value       = var.vpc_id
}

output "requester_vpc_cidrs" {
  description = "Every CIDR of the requester VPC (primary and secondary), as read."
  value       = local._hub_cidrs
}

output "route_ids" {
  description = "The hub-side routes, by route table id."
  value       = { for k, r in aws_route.to_peer : k => r.id }
}
