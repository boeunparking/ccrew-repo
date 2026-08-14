output "endpoint_id" {
  value = aws_ec2_client_vpn_endpoint.this.id
}

output "endpoint_dns" {
  value = aws_ec2_client_vpn_endpoint.this.dns_name
}

output "vpn_client_cidr" {
  value = var.client_cidr_block
}
