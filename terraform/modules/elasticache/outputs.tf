output "primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "cache_sg_id" {
  value = aws_security_group.cache.id
}

# CloudWatch 의 AWS/ElastiCache 지표는 복제 그룹이 아니라 노드(CacheClusterId) 단위로만
# 나온다. Grafana 대시보드가 노드별 CPU/메모리를 그리려면 이 목록이 필요하다.
# (예: cloud-duck-seoul-valkey-001, -002)
output "member_clusters" {
  description = "복제 그룹에 속한 노드 ID 목록 (CloudWatch CacheClusterId dimension)"
  value       = tolist(aws_elasticache_replication_group.this.member_clusters)
}
