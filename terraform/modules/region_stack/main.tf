### VPC ###
module "vpc" {
  source         = "../vpc"
  region         = var.region
  vpc_cidr_block = var.vpc_cidr_block
  pjt_name       = "${var.pjt_prefix}-vpc"
}


### 서브넷 Subnet ###
locals {
  public_subnets = { for k, v in var.subnets : k => v if v.tier == "public" }
  ecs_subnets    = { for k, v in var.subnets : k => v if v.tier == "ecs" }
  db_subnets     = { for k, v in var.subnets : k => v if v.tier == "db" }

  # NACL 규칙에 쓸 서브넷 그룹 CIDR을 vpc_cidr_block 기준으로 자동 계산
  # (public: sn1+sn2, ecs: sn3+sn4, db: sn5+sn6 가 각각 /23으로 붙어있다는 전제)
  pub_cidr_23 = cidrsubnet(var.vpc_cidr_block, 7, 0)
  ecs_cidr_23 = cidrsubnet(var.vpc_cidr_block, 7, 1)
  db_cidr_23  = cidrsubnet(var.vpc_cidr_block, 7, 2)

  nacl_ids = {
    alb = module.alb_nacl.nacl_id
    ecs = module.ecs_nacl.nacl_id
    db  = module.db_nacl.nacl_id
  }

  nacl_rules = {
    # --- ALB NACL ---
    alb_ingress_https         = { nacl = "alb", rule_number = 100, egress = false, cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 }
    alb_egress_to_user        = { nacl = "alb", rule_number = 110, egress = true, cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 }
    alb_egress_to_ecr         = { nacl = "alb", rule_number = 120, egress = true, cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 }
    alb_ingress_from_ecr      = { nacl = "alb", rule_number = 130, egress = false, cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 }
    alb_egress_to_ecs_sn34    = { nacl = "alb", rule_number = 140, egress = true, cidr_block = local.ecs_cidr_23, from_port = 3000, to_port = 3000 }
    alb_ingress_from_ecs_sn34 = { nacl = "alb", rule_number = 150, egress = false, cidr_block = local.ecs_cidr_23, from_port = 1024, to_port = 65535 }

    # --- ECS NACL ---
    ecs_ingress_from_alb_sn12 = { nacl = "ecs", rule_number = 200, egress = false, cidr_block = local.pub_cidr_23, from_port = 3000, to_port = 3000 }
    ecs_egress_to_alb_sn12    = { nacl = "ecs", rule_number = 210, egress = true, cidr_block = local.pub_cidr_23, from_port = 1024, to_port = 65535 }
    ecs_egress_to_ecr         = { nacl = "ecs", rule_number = 220, egress = true, cidr_block = "0.0.0.0/0", from_port = 443, to_port = 443 }
    ecs_ingress_from_ecr      = { nacl = "ecs", rule_number = 230, egress = false, cidr_block = "0.0.0.0/0", from_port = 1024, to_port = 65535 }
    ecs_egress_to_db_sn56     = { nacl = "ecs", rule_number = 240, egress = true, cidr_block = local.db_cidr_23, from_port = 3306, to_port = 3306 }
    ecs_ingress_from_db_sn56  = { nacl = "ecs", rule_number = 250, egress = false, cidr_block = local.db_cidr_23, from_port = 1024, to_port = 65535 }
    ecs_egress_to_redis       = { nacl = "ecs", rule_number = 242, egress = true, cidr_block = local.db_cidr_23, from_port = 6379, to_port = 6379 }

    # --- DB NACL ---
    db_ingress_from_ecs_sn34  = { nacl = "db", rule_number = 300, egress = false, cidr_block = local.ecs_cidr_23, from_port = 3306, to_port = 3306 }
    db_egress_to_ecs_sn34     = { nacl = "db", rule_number = 310, egress = true, cidr_block = local.ecs_cidr_23, from_port = 1024, to_port = 65535 }
    db_ingress_from_ecs_redis = { nacl = "db", rule_number = 302, egress = false, cidr_block = local.ecs_cidr_23, from_port = 6379, to_port = 6379 }
  }
}

module "subnet" {
  source     = "../subnet"
  vpc_id     = module.vpc.vpc_id
  for_each   = var.subnets
  region     = var.region
  cidr_block = each.value.cidr
  az_name    = each.value.az
  pjt_name   = "tf-${var.pjt_prefix}-${each.key}"
}


### 라우팅 테이블 Routing Table ###

module "pub_rt" {
  source   = "../route_table"
  vpc_id   = module.vpc.vpc_id
  pjt_name = "tf-${var.pjt_prefix}-pub-rt12"
}

resource "aws_route_table_association" "public" {
  for_each       = local.public_subnets
  subnet_id      = module.subnet[each.key].sn_id
  route_table_id = module.pub_rt.rt_id
}

resource "aws_route" "pub_default" {
  route_table_id         = module.pub_rt.rt_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id              = module.vpc.igw_id
}

resource "aws_eip" "nat_eip" {
  tags = {
    Name = "tf-${var.pjt_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = module.subnet[sort(keys(local.public_subnets))[0]].sn_id

  tags = {
    Name = "tf-${var.pjt_prefix}-nat-gw"
  }
  depends_on = [module.vpc]
}

module "pri_rt" {
  source   = "../route_table"
  vpc_id   = module.vpc.vpc_id
  pjt_name = "tf-${var.pjt_prefix}-pri-rt34"
}

resource "aws_route_table_association" "ecs" {
  for_each       = local.ecs_subnets
  subnet_id      = module.subnet[each.key].sn_id
  route_table_id = module.pri_rt.rt_id
}

resource "aws_route" "pri_default" {
  route_table_id         = module.pri_rt.rt_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id              = aws_nat_gateway.nat_gw.id
  depends_on              = [aws_nat_gateway.nat_gw]
}

module "db_rt" {
  source   = "../route_table"
  vpc_id   = module.vpc.vpc_id
  pjt_name = "tf-${var.pjt_prefix}-db-rt56"
}

resource "aws_route_table_association" "db" {
  for_each       = local.db_subnets
  subnet_id      = module.subnet[each.key].sn_id
  route_table_id = module.db_rt.rt_id
}


### 보안그룹 SG Security Group ###

module "alb_sg" {
  source   = "../security_group"
  region   = var.region
  pjt_name = "tf-${var.pjt_prefix}-alb-sg"
  vpc_id   = module.vpc.vpc_id
  desc     = "Allow HTTP, HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = module.alb_sg.sg_id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 443
  ip_protocol        = "tcp"
  to_port            = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = module.alb_sg.sg_id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 80
  ip_protocol        = "tcp"
  to_port            = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_egress" {
  security_group_id = module.alb_sg.sg_id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1" # semantically equivalent to all ports
}

module "ecs_sg" {
  source   = "../security_group"
  region   = var.region
  pjt_name = "tf-${var.pjt_prefix}-ecs-sg"
  vpc_id   = module.vpc.vpc_id
  desc     = "Allow 3000"
}

resource "aws_vpc_security_group_ingress_rule" "ecs_ingress" {
  security_group_id            = module.ecs_sg.sg_id
  referenced_security_group_id = module.alb_sg.sg_id
  from_port                    = 3000
  ip_protocol                  = "tcp"
  to_port                      = 3000
}

resource "aws_vpc_security_group_egress_rule" "ecs_egress" {
  security_group_id = module.ecs_sg.sg_id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1" # semantically equivalent to all ports
}

module "db_sg" {
  source   = "../security_group"
  region   = var.region
  pjt_name = "tf-${var.pjt_prefix}-db-sg"
  vpc_id   = module.vpc.vpc_id
  desc     = "Allow 3306"
}

resource "aws_vpc_security_group_ingress_rule" "db_ingress" {
  security_group_id            = module.db_sg.sg_id
  referenced_security_group_id = module.ecs_sg.sg_id
  from_port                    = 3306
  ip_protocol                  = "tcp"
  to_port                      = 3306
}


### NACL 네트워크 ACL ###

module "alb_nacl" {
  source     = "../nacl"
  region     = var.region
  pjt_name   = "tf-${var.pjt_prefix}-alb-nacl"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = [for k in sort(keys(local.public_subnets)) : module.subnet[k].sn_id]
}

module "ecs_nacl" {
  source     = "../nacl"
  region     = var.region
  pjt_name   = "tf-${var.pjt_prefix}-ecs-nacl"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = [for k in sort(keys(local.ecs_subnets)) : module.subnet[k].sn_id]
}

module "db_nacl" {
  source     = "../nacl"
  region     = var.region
  pjt_name   = "tf-${var.pjt_prefix}-db-nacl"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = [for k in sort(keys(local.db_subnets)) : module.subnet[k].sn_id]
}

resource "aws_network_acl_rule" "this" {
  for_each       = local.nacl_rules
  network_acl_id = local.nacl_ids[each.value.nacl]
  rule_number    = each.value.rule_number
  egress         = each.value.egress
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr_block
  from_port      = each.value.from_port
  to_port        = each.value.to_port
}
