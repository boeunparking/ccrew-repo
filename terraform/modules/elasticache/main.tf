########################################
# Subnet Group
########################################
resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project}-${var.name}-cache-subnet-group"
  subnet_ids = var.subnet_ids
}

########################################
# 보안그룹 — Redis 매트릭스 반영
# ECS → Redis 6379 (ecs 슈퍼넷 → db 슈퍼넷)
########################################
resource "aws_security_group" "cache" {
  name        = "${var.project}-${var.name}-cache-sg"
  description = "ElastiCache Valkey - allow 6379 from ECS SG"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Valkey from ECS"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.ecs_sg_id]
  }

  tags = { Name = "${var.project}-${var.name}-cache-sg" }
}

########################################
# Valkey 캐시 (cache.t4g.micro, 단일 노드)
########################################
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.project}-${var.name}-valkey"
  description          = "cloud-duck Valkey cache (${var.name})"

  engine         = var.engine # valkey
  engine_version = var.engine_version
  node_type      = var.node_type

  num_cache_clusters         = var.num_cache_clusters # 단일 노드
  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  snapshot_retention_limit = 1
  maintenance_window       = "sun:19:00-sun:20:00"

  tags = { Name = "${var.project}-${var.name}-valkey" }
}
