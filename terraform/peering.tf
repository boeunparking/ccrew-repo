### 서울 <-> 도쿄 VPC 피어링 ###
# 목적: 서울(active) RDS Primary <-> 도쿄(warm standby) RDS Replica 간 복제 트래픽(3306)

resource "aws_vpc_peering_connection" "seoul_tokyo" {
  vpc_id      = module.seoul.vpc_id
  peer_vpc_id = module.tokyo.vpc_id
  peer_region = var.region_tokyo

  tags = {
    Name = "seoul-tokyo-peering"
  }
}

resource "aws_vpc_peering_connection_accepter" "seoul_tokyo" {
  provider                  = aws.tokyo
  vpc_peering_connection_id = aws_vpc_peering_connection.seoul_tokyo.id
  auto_accept                = true

  tags = {
    Name = "seoul-tokyo-peering-accept"
  }
}


### 라우팅: DB 라우팅 테이블에서만 상대 리전 VPC로 경로 추가 ###
# (복제 트래픽은 db 계층끼리만 오가므로 pub/pri 라우팅 테이블은 건드리지 않음)

resource "aws_route" "seoul_db_to_tokyo" {
  route_table_id            = module.seoul.route_table_ids["db"]
  destination_cidr_block    = var.vpc_cidr_tokyo
  vpc_peering_connection_id = aws_vpc_peering_connection.seoul_tokyo.id
  depends_on                 = [aws_vpc_peering_connection_accepter.seoul_tokyo]
}

resource "aws_route" "tokyo_db_to_seoul" {
  provider                   = aws.tokyo
  route_table_id             = module.tokyo.route_table_ids["db"]
  destination_cidr_block     = var.vpc_cidr_seoul
  vpc_peering_connection_id  = aws_vpc_peering_connection.seoul_tokyo.id
  depends_on                  = [aws_vpc_peering_connection_accepter.seoul_tokyo]
}


### 보안그룹: 서울 DB가 도쿄(replica)의 접속을 받아들이도록 3306 인바운드 허용 ###
# 교차 리전 피어링에서는 SG-to-SG 참조(referenced_security_group_id)를 못 쓰기 때문에 CIDR로 허용
# (도쿄 -> 서울로 나가는 아웃바운드는 SG 기본 egress로 이미 허용되어 별도 규칙 불필요)

resource "aws_vpc_security_group_ingress_rule" "seoul_db_from_tokyo_replica" {
  security_group_id = module.seoul.db_sg_id
  cidr_ipv4          = module.tokyo.db_cidr_23
  from_port          = 3306
  ip_protocol        = "tcp"
  to_port            = 3306
}


### NACL: db-sn 계층끼리만 3306(+ephemeral 응답) 허용 ###

# 서울 DB NACL: 도쿄 replica 접속을 받고(ingress 3306), 응답은 돌려보냄(egress ephemeral)
resource "aws_network_acl_rule" "seoul_db_nacl_ingress_tokyo" {
  network_acl_id = module.seoul.db_nacl_id
  rule_number    = 320
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = module.tokyo.db_cidr_23
  from_port      = 3306
  to_port        = 3306
}

resource "aws_network_acl_rule" "seoul_db_nacl_egress_tokyo" {
  network_acl_id = module.seoul.db_nacl_id
  rule_number    = 321
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = module.tokyo.db_cidr_23
  from_port      = 1024
  to_port        = 65535
}

# 도쿄 DB NACL: 서울로 접속을 나가고(egress 3306), 응답을 받음(ingress ephemeral)
resource "aws_network_acl_rule" "tokyo_db_nacl_egress_seoul" {
  provider       = aws.tokyo
  network_acl_id = module.tokyo.db_nacl_id
  rule_number    = 320
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = module.seoul.db_cidr_23
  from_port      = 3306
  to_port        = 3306
}

resource "aws_network_acl_rule" "tokyo_db_nacl_ingress_seoul" {
  provider       = aws.tokyo
  network_acl_id = module.tokyo.db_nacl_id
  rule_number    = 321
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = module.seoul.db_cidr_23
  from_port      = 1024
  to_port        = 65535
}
