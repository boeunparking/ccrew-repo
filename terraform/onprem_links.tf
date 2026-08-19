############################################################
# 온프레미스 ↔ 서울 연동 규칙#
############################################################

# 서울 ECS SG ← 온프레미스 전체 허용 (백업/복원 트래픽)
resource "aws_vpc_security_group_ingress_rule" "onprem_to_ecs" {

  security_group_id = module.seoul.ecs_sg_id
  description       = "From onprem VPC (backup/restore)"
  cidr_ipv4         = var.onprem_vpc_cidr
  ip_protocol       = "-1"
}

# 서울 DB SG ← 온프레미스 3306 (MinIO 서버에서 DB 백업 덤프용)
resource "aws_vpc_security_group_ingress_rule" "onprem_to_db" {

  security_group_id = module.seoul.db_sg_id
  description       = "MySQL from onprem VPC"
  cidr_ipv4         = var.onprem_vpc_cidr
  from_port         = 3306
  to_port           = 3306
  ip_protocol       = "tcp"
}

# 서울 DB NACL — SG 만 열면 NACL(ECS 대역만 허용)에서 막히므로 규칙 추가
# rule_number 는 ccrew-tf 가 쓰는 100~310 과 겹치지 않게 320번대 사용
resource "aws_network_acl_rule" "db_in_from_onprem" {

  network_acl_id = module.seoul.db_nacl_id
  rule_number    = 330
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.onprem_vpc_cidr
  from_port      = 3306
  to_port        = 3306
}

resource "aws_network_acl_rule" "db_out_to_onprem" {

  network_acl_id = module.seoul.db_nacl_id
  rule_number    = 330
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.onprem_vpc_cidr
  from_port      = 1024
  to_port        = 65535
}
