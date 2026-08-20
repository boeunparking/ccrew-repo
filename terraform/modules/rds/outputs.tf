output "primary_arn" {
  value = try(aws_db_instance.primary[0].arn, null)
}

output "primary_identifier" {
  value = try(aws_db_instance.primary[0].identifier, null)
}

output "primary_endpoint" {
  value = try(aws_db_instance.primary[0].endpoint, null)
}

output "replica_endpoint" {
  value = try(
    aws_db_instance.replica[0].endpoint,
    aws_db_instance.cross_region_replica[0].endpoint,
    null
  )
}

# ECS 환경변수(DB_HOST)용 — endpoint는 "host:port" 형태라 앱이 DB_PORT를 따로 읽는
# db.js와는 안 맞는다. .address는 포트 없는 순수 호스트명이다.
output "db_address" {
  description = "포트 없는 DB 호스트명 (primary가 없으면 replica/cross_region_replica 순으로 사용)"
  value = try(
    aws_db_instance.primary[0].address,
    aws_db_instance.replica[0].address,
    aws_db_instance.cross_region_replica[0].address,
    null
  )
}

output "db_sg_id" {
  value = aws_security_group.db.id
}

output "secret_arn" {
  value = try(aws_secretsmanager_secret.db[0].arn, null)
}

output "primary_password" {
  description = "Primary DB 비밀번호 (크로스 리전 replica 쪽 Secrets Manager 시크릿 생성 시 전달용)"
  value       = try(random_password.db[0].result, null)
  sensitive   = true
}
