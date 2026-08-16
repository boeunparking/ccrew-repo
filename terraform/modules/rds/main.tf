########################################
# DB Subnet Group (tf-db-sn5, tf-db-sn6)
########################################
resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-${var.name}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = { Name = "${var.project}-${var.name}-db-subnet-group" }
}

########################################
# 보안그룹 tf-db-sg
# 인바운드: TCP 3306 ← ecs_sg (+ VPN 클라이언트 CIDR)
# 아웃바운드: X (stateful이므로 응답은 자동 허용)
########################################
resource "aws_security_group" "db" {
  name        = "${var.project}-${var.name}-db-sg"
  description = "RDS MySQL - allow 3306 from ECS SG"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from ECS"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [var.ecs_sg_id]
  }

  dynamic "ingress" {
    for_each = var.vpn_client_cidr != null ? [1] : []
    content {
      description = "MySQL from VPN admin"
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      cidr_blocks = [var.vpn_client_cidr]
    }
  }

  tags = { Name = "${var.project}-${var.name}-db-sg" }
}

########################################
# Secrets Manager 암호 관리 (담당: 하윤)
########################################
resource "random_password" "db" {
  count            = var.create_primary ? 1 : 0
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "db" {
  count                   = var.create_primary ? 1 : 0
  name                    = "${var.project}/${var.name}/rds/admin"
  description             = "RDS MySQL admin password - managed by hayoon"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db" {
  count     = var.create_primary ? 1 : 0
  secret_id = aws_secretsmanager_secret.db[0].id
  secret_string = jsonencode({
    username = var.username
    password = random_password.db[0].result
    engine   = "mysql"
    port     = 3306
  })
}

########################################
# RDS Primary (MySQL 8.0, db.t4g.micro, Multi-AZ)
########################################
resource "aws_db_instance" "primary" {
  count = var.create_primary ? 1 : 0

  identifier     = "${var.project}-${var.name}-primary"
  availability_zone  = var.primary_availability_zone  #추가
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  username = var.username
  password = random_password.db[0].result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                = var.multi_az # multi_az=false -> free tier 때문에
  backup_retention_period = var.backup_retention_period
  backup_window           = "17:00-18:00" # UTC = KST 02:00-03:00
  maintenance_window      = "sun:18:00-sun:19:00"

  auto_minor_version_upgrade = true
  deletion_protection        = false
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.project}-${var.name}-final"

  performance_insights_enabled = false # t4g.micro 프리티어 고려

  tags = { Name = "${var.project}-${var.name}-rds-primary" }
}

########################################
# 같은 리전 Read Replica (db.t4g.micro)
########################################
resource "aws_db_instance" "replica" {
  count = var.create_replica && var.create_primary ? 1 : 0

  identifier          = "${var.project}-${var.name}-replica"
  availability_zone    = var.replica_availability_zone  # 추가
  replicate_source_db = aws_db_instance.primary[0].identifier
  instance_class      = var.instance_class

  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  storage_encrypted      = true
  skip_final_snapshot    = true

  tags = { Name = "${var.project}-${var.name}-rds-replica" }
}

########################################
# 크로스 리전 Replica 전용 모드
# (도쿄 warm standby에서 create_primary=false 로 사용)
########################################
resource "aws_db_instance" "cross_region_replica" {
  count = var.create_cross_region_replica ? 1 : 0
  kms_key_id           = var.kms_key_id

  identifier          = "${var.project}-${var.name}-replica"
  replicate_source_db = var.replicate_source_db # 소스 DB의 ARN
  instance_class      = var.instance_class

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  storage_encrypted      = true
  skip_final_snapshot    = true

  tags = { Name = "${var.project}-${var.name}-rds-replica" }
}
