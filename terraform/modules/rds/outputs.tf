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
