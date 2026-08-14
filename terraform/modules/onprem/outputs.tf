# 루트의 peering_seoul_onprem 모듈이 참조하는 값들
output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "route_table_id" {
  value = aws_route_table.rt1.id
}

output "instance_id" {
  description = "SSM Session Manager 접속 대상 (aws ssm start-session --target <id>)"
  value       = aws_instance.app.id
}

output "instance_private_ip" {
  value = aws_instance.app.private_ip
}
