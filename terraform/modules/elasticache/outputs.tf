output "primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "cache_sg_id" {
  value = aws_security_group.cache.id
}
