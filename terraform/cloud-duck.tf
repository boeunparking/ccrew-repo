############################################################
# cloud-duck 인프라
# 서울(Active) + 도쿄(Warm Standby/DR)
#
# 모듈 6종
#   1. rds          : Primary(Multi-AZ) + Replica + 도쿄 크로스리전 Replica
#   2. elasticache  : Valkey (cache.t4g.micro, 단일 노드) — 양 리전
#   3. s3           : Source(서울) + CRR(도쿄)
#   4. client-vpn   : 관리자 → DB 접근 (서울)
#   5. cloudwatch   : CPU 80% 5분 알람 + SNS + 대시보드
#   6. vpc-peering  : Site-to-Site VPN 대체 (구성도 표기만 VPN)
#   7. onprem       : 온프레미스(로 표기) VPC + MinIO EC2 (서울 2b)
#
# 네트워크(VPC/Subnet/RouteTable/SG/NACL)는 ccrew-tf 의 region_stack 모듈이
# 서울(172.16.0.0/16) / 도쿄(172.17.0.0/16) 두 리전에 이미 생성한다.
# ccrew-tf 와는 state 가 분리되어 있으므로 여기서는 ID 를 변수로 받는다.
# 온프레미스(10.0.0.0/16)는 이 스택(module.onprem)이 직접 생성한다.
############################################################

########################################
# 1. RDS — 서울: Primary(Multi-AZ) + 같은 리전 Replica
########################################
module "rds_seoul" {
  source = "./modules/rds"

  project    = var.project
  name       = "seoul"
  vpc_id     = module.seoul_vpc_id
  subnet_ids = [module.seoul.subnet_ids["db-sn5"],
                module.seoul.subnet_ids["db-sn6"]] # tf-seoul-db-sn5, tf-seoul-db-sn6
  ecs_sg_id  = module.seoul.ecs_sg_id      # tf-seoul-ecs-sg

  # VPN 관리자 → DB 3306 허용 (VPN 관리자 접근 매트릭스)
  vpn_client_cidr = var.vpn_client_cidr

  create_primary = true
  multi_az       = true # RDS(multi-az) 결정사항
  create_replica = true # RDS replica (db.t4g.micro)
}

########################################
# 1'. RDS — 도쿄: 크로스 리전 Read Replica (Warm Standby)
########################################
module "rds_tokyo_replica" {
  source = "./modules/rds"
  providers = {
    aws = aws.tokyo
  }

  project    = var.project
  name       = "tokyo"
  vpc_id     = module.tokyo_vpc_id
  subnet_ids = [module.tokyo.subnet_ids["db-sn5"],
                module.tokyo.subnet_ids["db-sn6"]] # tf-tokyo-db-sn5, tf-tokyo-db-sn6
  ecs_sg_id  = module.tokyo_ecs_sg_id     # tf-tokyo-ecs-sg

  create_primary      = false
  create_replica      = false
  replicate_source_db = module.rds_seoul.primary_arn # 크로스 리전은 ARN 필요
}

########################################
# 2. ElastiCache Valkey — 서울 / 도쿄 각 1클러스터 (구성도 기준)
########################################
module "cache_seoul" {
  source = "./modules/elasticache"


  project    = var.project
  name       = "seoul"
  vpc_id     = module.seoul_vpc_id
  subnet_ids = [module.seoul.subnet_ids["db-sn5"],
                module.seoul.subnet_ids["db-sn6"]]
  ecs_sg_id  = module.seoul_ecs_sg_id

  num_cache_clusters = 2 # 3주 스코프 → 단일 노드 권장
}

module "cache_tokyo" {
  source = "./modules/elasticache"
  providers = {
    aws = aws.tokyo
  }

  project    = var.project
  name       = "tokyo"
  vpc_id     = module.tokyo_vpc_id
  subnet_ids = [module.tokyo.subnet_ids["db-sn5"],
                module.tokyo.subnet_ids["db-sn6"]]
  ecs_sg_id  = module.tokyo_ecs_sg_id

  num_cache_clusters = 2
}

########################################
# 3. S3 — Source(서울) + CRR(도쿄)
########################################
module "s3" {
  source = "./modules/s3"
  providers = {
    aws.source      = aws
    aws.destination = aws.tokyo
  }

  project                 = var.project
  source_bucket_name      = "${var.project}-source-apne2"
  destination_bucket_name = "${var.project}-crr-apne1"
}

########################################
# 4. AWS Client VPN — 관리자 DB 접근 (서울)
########################################
module "client_vpn" {
  source = "./modules/client-vpn"

  project           = var.project
  vpc_id            = module.seoul_vpc_id
  target_subnet_ids = [module.seoul.subnet_ids["db-sn5"],
                       module.seoul.subnet_ids["db-sn6"]]
  client_cidr_block = var.vpn_client_cidr
  authorized_cidrs  = [var.subnets_seoul["db-sn5"].cidr,
                       var.subnets_seoul["db-sn6"].cidr] # tf-seoul-db-sn5/sn6 대역만 인가

  server_certificate_arn      = var.vpn_server_cert_arn
  client_root_certificate_arn = var.vpn_client_root_cert_arn
}

########################################
# 5. CloudWatch — 알람(CPU 80% 5분) + SNS + 대시보드 (서울)
########################################
module "cloudwatch_seoul" {
  source = "./modules/cloudwatch"

  project          = var.project
  name             = "seoul"
  alarm_email      = var.alarm_email
  ecs_cluster_name =  aws_ecs_cluster.tf_cluster.name
  ecs_service_name = module.web_service.service_name
  rds_identifier   = module.rds_seoul.primary_identifier
  alb_arn_suffix   = module.alb.alb_arn_suffix

  cpu_threshold  = 80  # 운영 결정사항: CPU 80%
  period_seconds = 300 # 5분 지속
}

########################################
# 7. 온프레미스 스택 — VPC/Subnet/IGW/RT + MinIO EC2 + EBS + DLM
#    같은 계정·서울 리전(ap-northeast-2b)에 "온프레미스로 표기"되는 환경 구성
########################################
module "onprem" {
  source = "./modules/onprem"

  project        = var.project
  vpc_cidr_block = var.onprem_vpc_cidr # 10.0.0.0/16
  seoul_vpc_cidr = var.vpc_cidr_seoul  # SG/NACL 인바운드 허용 대상
}

########################################
# 6. VPC Peering — Site-to-Site VPN 대체
#    구성도에는 Site-to-Site VPN으로 표기, 실제 구현은 피어링
#    서울 VPC ↔ 온프레미스(module.onprem 이 만든) VPC
#    양방향 라우트(서울 rt34/rt56 → 10.0.0.0/16, onprem-rt1 → 172.16.0.0/16)도
#    이 모듈이 자동 생성한다 — onprem 쪽에서 별도로 만들지 말 것
########################################
module "peering_seoul_onprem" {
  source = "./modules/vpc-peering"
  providers = {
    aws.requester = aws
    aws.accepter  = aws # 온프레미스 VPC가 같은 계정·서울 리전
  }

  project = var.project
  name    = "seoul-onprem"

  requester_vpc_id   = module.seoul.vpc_id
  accepter_vpc_id    = module.onprem.vpc_id
  requester_vpc_cidr = var.vpc_cidr_seoul # 172.16.0.0/16
  accepter_vpc_cidr  = module.onprem.vpc_cidr_block

  requester_route_table_ids = [module.seoul.route_table_ids["pri"],
                               module.seoul.route_table_ids["db"]] # tf-seoul-pri-rt34, tf-seoul-db-rt56
  accepter_route_table_ids  = [module.onprem.route_table_id]
}



