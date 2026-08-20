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

output "eip_public_ip" {
  description = "Customer Gateway에 등록할 온프레미스(EC2)의 고정 공인 IP"
  value       = aws_eip.app.public_ip
}

output "role_name" {
  description = "onprem-app-role 이름 — 루트에서 추가 IAM 정책(PII 백업용 Secrets Manager 읽기 등)을 붙일 때 참조"
  value       = aws_iam_role.app.name
}

output "minio_volume_id" {
  description = "MinIO 데이터용 EBS 볼륨 ID — 루트에서 SSM 설치 스크립트가 디바이스를 찾을 때 참조"
  value       = aws_ebs_volume.minio.id
}
