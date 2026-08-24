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
# create_primary=false(replica 전용 모드)여도 create_secret=true면 시크릿을 만든다.
# 이 경우 username/password는 소스 DB에서 그대로 전달받고(RDS replica는 자체 비밀번호를
# 가질 수 없음), host만 이 리전의 replica 엔드포인트로 저장한다.
########################################
locals {
  create_secret_effective = var.create_primary || var.create_secret
}

resource "random_password" "db" {
  count            = var.create_primary ? 1 : 0
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "db" {
  count                   = local.create_secret_effective ? 1 : 0
  name                    = "${var.project}/${var.name}/rds/admin"
  description             = "RDS MySQL admin password - managed by hayoon"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  count     = local.create_secret_effective ? 1 : 0
  secret_id = aws_secretsmanager_secret.db[0].id
  secret_string = jsonencode({
    username = var.create_primary ? var.username : var.secret_username
    password = var.create_primary ? random_password.db[0].result : var.secret_password
    engine   = "mysql"
    port     = 3306
    host     = var.create_primary ? try(aws_db_instance.primary[0].address, null) : try(aws_db_instance.cross_region_replica[0].address, null)
  })
}

########################################
# RDS Primary (MySQL 8.0, db.t4g.micro, Multi-AZ)
########################################
resource "aws_db_instance" "primary" {
  count = var.create_primary ? 1 : 0

  identifier = "${var.project}-${var.name}-primary"

  # Multi-AZ는 AWS가 여러 AZ에 걸쳐 배치하는 방식이라 AZ를 하나로 고정할 수 없다
  # ("Requesting a specific availability zone is not valid for Multi-AZ instances").
  # 단일 AZ 구성일 때만 구성도상의 지정 AZ(ap-northeast-2a)를 적용한다.
  availability_zone = var.multi_az ? null : var.primary_availability_zone
  engine            = "mysql"
  engine_version    = var.engine_version
  instance_class    = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  # kms_key_id는 일부러 안 씀: null(기본 관리형 키)을 명시하면 Terraform이
  # "설정값이 바뀌었다"고 오인해 실제 운영 중인 RDS를 강제로 재생성(삭제+재생성)한다.
  # 크로스 리전 replica(cross_region_replica)는 KMS 지정이 필수라 거기서는 그대로 쓴다.

  username = var.username
  password = random_password.db[0].result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_period
  backup_window           = "17:00-18:00" # UTC = KST 02:00-03:00
  maintenance_window      = "sun:18:00-sun:19:00"

  auto_minor_version_upgrade = true
  deletion_protection        = false

  # destroy 시 최종 스냅샷을 남기지 않는다.
  #
  # 남기면 destroy 는 "성공"인데 스냅샷은 계속 남아 과금된다. 아무도 안 지우면
  # 재구축을 반복할수록 쌓이고, 정작 필요할 때 어느 게 어느 시점인지 알 수 없다.
  # 이름 충돌 문제도 있었다 — 고정 이름을 쓰면 지난 destroy 가 남긴 스냅샷과
  # 부딪혀 DBSnapshotAlreadyExists 로 destroy 가 통째로 막힌다(2026-08-22 실제 발생).
  #
  # ⚠ 대신 destroy 하면 DB 내용이 그대로 사라진다. 되돌릴 수 없다.
  #    이 스택의 DB 는 앱이 부팅할 때 스키마를 다시 만들고(web/src/schema.js),
  #    보관해야 할 데이터가 생기면 backup_retention_period 의 자동 백업이나
  #    수동 스냅샷으로 따로 챙기는 전제다.
  skip_final_snapshot = true

  performance_insights_enabled = false # t4g.micro 프리티어 고려

  tags = { Name = "${var.project}-${var.name}-rds-primary" }
}

########################################
# 같은 리전 Read Replica (db.t4g.micro)
########################################
resource "aws_db_instance" "replica" {
  count = var.create_replica && var.create_primary ? 1 : 0

  identifier          = "${var.project}-${var.name}-replica"
  availability_zone   = var.replica_availability_zone # 추가
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
  count      = var.create_cross_region_replica ? 1 : 0
  kms_key_id = var.kms_key_id

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