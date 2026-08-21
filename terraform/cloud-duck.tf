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
#   6. site-to-site-vpn : 서울 ↔ 온프레미스 (VGW/CGW/VPN Connection, EC2가 strongSwan으로 종단)
#   7. onprem       : 온프레미스(로 표기) VPC + MinIO EC2 (서울 2b)
#
# 네트워크(VPC/Subnet/RouteTable/SG/NACL)는 ccrew-tf 의 region_stack 모듈이
# 서울(172.16.0.0/16) / 도쿄(172.17.0.0/16) 두 리전에 이미 생성한다.
# ccrew-tf 와는 state 가 분리되어 있으므로 여기서는 ID 를 변수로 받는다.
# 온프레미스(10.0.0.0/16)는 이 스택(module.onprem)이 직접 생성한다.
############################################################

########################################
# 0. KMS — 서울 리전 데이터 암호화용 (RDS + S3 Source 공용)
# 도쿄는 aws_kms_key.rds_tokyo(파일 하단)가 이미 같은 역할을 한다.
########################################
resource "aws_kms_key" "seoul" {
  description             = "cloud-duck 서울 리전 데이터 암호화용 (RDS + S3)"
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "seoul" {
  name          = "alias/cloud-duck-seoul"
  target_key_id = aws_kms_key.seoul.key_id
}

########################################
# 1. RDS — 서울: Primary(2a) + 같은 리전 Replica(2c), Multi-AZ 미사용
########################################
module "rds_seoul" {
  source = "./modules/rds"

  project = var.project
  name    = "seoul"
  vpc_id  = module.seoul.vpc_id
  subnet_ids = [module.seoul.subnet_ids["db-sn5"],
  module.seoul.subnet_ids["db-sn6"]] # tf-seoul-db-sn5, tf-seoul-db-sn6
  ecs_sg_id = module.seoul.ecs_sg_id # tf-seoul-ecs-sg

  # VPN 관리자 → DB 3306 허용 (VPN 관리자 접근 매트릭스)
  vpn_client_cidr = var.vpn_client_cidr

  create_primary            = true
  multi_az                  = true # 프리티어 아님 - Multi-AZ 활성화
  create_replica            = true # RDS replica (db.t4g.micro)
  primary_availability_zone = "ap-northeast-2a"
  replica_availability_zone = "ap-northeast-2c"
  kms_key_id                = aws_kms_key.seoul.arn
}

########################################
# 1'. RDS — 도쿄: 크로스 리전 Read Replica (Warm Standby)
########################################
module "rds_tokyo_replica" {
  source = "./modules/rds"
  providers = {
    aws = aws.tokyo
  }

  project = var.project
  name    = "tokyo"
  vpc_id  = module.tokyo.vpc_id
  subnet_ids = [module.tokyo.subnet_ids["db-sn5"],
  module.tokyo.subnet_ids["db-sn6"]] # tf-tokyo-db-sn5, tf-tokyo-db-sn6
  ecs_sg_id = module.tokyo.ecs_sg_id # tf-tokyo-ecs-sg

  create_primary              = false
  create_replica              = false
  create_cross_region_replica = true
  kms_key_id                  = aws_kms_key.rds_tokyo.arn
  replicate_source_db         = module.rds_seoul.primary_arn # 크로스 리전은 ARN 필요

  # 도쿄용 Secrets Manager — replica는 자체 비밀번호를 가질 수 없으므로
  # 서울 primary와 동일한 계정정보를 그대로 저장하고, host만 도쿄 replica 엔드포인트로 기록한다.
  create_secret   = true
  secret_username = "admin" # modules/rds username 기본값과 동일 (rds_seoul도 기본값 사용 중)
  secret_password = module.rds_seoul.primary_password
}

########################################
# 2. ElastiCache Valkey — 서울 / 도쿄 각 1클러스터 (구성도 기준)
########################################
module "cache_seoul" {
  source = "./modules/elasticache"


  project = var.project
  name    = "seoul"
  vpc_id  = module.seoul.vpc_id
  subnet_ids = [module.seoul.subnet_ids["db-sn5"],
  module.seoul.subnet_ids["db-sn6"]]
  ecs_sg_id = module.seoul.ecs_sg_id

  num_cache_clusters = 2 # 3주 스코프 → 단일 노드 권장
}

module "cache_tokyo" {
  source = "./modules/elasticache"
  providers = {
    aws = aws.tokyo
  }

  project = var.project
  name    = "tokyo"
  vpc_id  = module.tokyo.vpc_id
  subnet_ids = [module.tokyo.subnet_ids["db-sn5"],
  module.tokyo.subnet_ids["db-sn6"]]
  ecs_sg_id = module.tokyo.ecs_sg_id

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
  source_kms_key_id       = aws_kms_key.seoul.arn
}

########################################
# 4. AWS Client VPN — 관리자 DB 접근 (서울)
########################################
module "client_vpn" {
  source = "./modules/client-vpn"

  project = var.project
  vpc_id  = module.seoul.vpc_id
  target_subnet_ids = [module.seoul.subnet_ids["db-sn5"],
  module.seoul.subnet_ids["db-sn6"]]
  client_cidr_block = var.vpn_client_cidr
  authorized_cidrs = [var.subnets_seoul["db-sn5"].cidr,
  var.subnets_seoul["db-sn6"].cidr] # tf-seoul-db-sn5/sn6 대역만 인가

  server_certificate_arn      = var.vpn_server_cert_arn
  client_root_certificate_arn = var.vpn_client_root_cert_arn
}

########################################
# 5. CloudWatch — 알람(CPU 80% 5분) + SNS + 대시보드 (서울)
########################################
module "cloudwatch_seoul" {
  source = "./modules/cloudwatch"

  project           = var.project
  name              = "seoul"
  alarm_email       = var.alarm_email
  ecs_cluster_name  = aws_ecs_cluster.tf_cluster.name
  ecs_service_name  = module.web_service.service_name
  rds_identifier    = module.rds_seoul.primary_identifier
  create_rds_alarms = true
  alb_arn_suffix    = module.alb.alb_arn_suffix
  create_alb_alarm  = true

  cpu_threshold  = 80  # 운영 결정사항: CPU 80%
  period_seconds = 300 # 5분 지속
}

########################################
# 5'. CloudWatch — 도쿄(Warm Standby)
#
# 서울과 같은 구성이되 두 가지가 다르다:
#   1) RDS 알람 제외 — 도쿄는 읽기 전용 replica라 서울 primary와 지표 성격이 다르고,
#      module의 RDS 알람은 primary_identifier를 전제로 만들어져 있다.
#   2) 대시보드 위젯 region을 도쿄로 넘긴다 — 알람/SNS는 provider를 따라가지만
#      대시보드 위젯은 본문에 리전을 직접 써야 해서 provider만으론 안 된다.
#
# SNS 토픽도 리전별로 따로 생긴다(SNS는 리전 서비스). 즉 도쿄 알람은 도쿄 토픽으로
# 발송되므로, 같은 alarm_email 주소로 구독 확인 메일이 한 번 더 온다.
########################################
module "cloudwatch_tokyo" {
  source = "./modules/cloudwatch"
  providers = {
    aws = aws.tokyo
  }

  project          = var.project
  name             = "tokyo"
  region           = var.region_tokyo
  alarm_email      = var.alarm_email
  ecs_cluster_name = aws_ecs_cluster.tf_cluster_tokyo.name
  ecs_service_name = module.web_service_tokyo.service_name

  # 도쿄는 replica라 primary 기준 알람(FreeStorage 등)을 그대로 쓰기 어렵다
  create_rds_alarms = false

  alb_arn_suffix   = module.alb_tokyo.alb_arn_suffix
  create_alb_alarm = true

  cpu_threshold  = 80
  period_seconds = 300
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
# 6. Site-to-Site VPN — 서울 VPC ↔ 온프레미스(module.onprem 이 만든) VPC
#    (구성도 그대로 실제 구현. 예전엔 VPC Peering으로 대체했으나 modules/vpc-peering는 삭제됨)
#    온프레미스에 실제 라우터가 없으므로 module.onprem의 EC2가 EIP를 물고
#    strongSwan으로 터널을 종단해 그 역할을 겸한다 (vpn-strongswan.tf).
########################################
module "site_to_site_vpn_onprem" {
  source = "./modules/site-to-site-vpn"

  project = var.project
  name    = "seoul-onprem"

  seoul_vpc_id = module.seoul.vpc_id
  seoul_route_table_ids = [module.seoul.route_table_ids["pri"],
  module.seoul.route_table_ids["db"]] # tf-seoul-pri-rt34, tf-seoul-db-rt56

  onprem_cidr         = module.onprem.vpc_cidr_block
  customer_gateway_ip = module.onprem.eip_public_ip
}

# cloud-duck.tf 맨 아래쪽에 추가

########################################
# KMS — 도쿄 크로스 리전 RDS Replica 암호화용
########################################
resource "aws_kms_key" "rds_tokyo" {
  provider                = aws.tokyo
  description             = "cloud-duck RDS cross-region replica 암호화용 (Tokyo)"
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "rds_tokyo" {
  provider      = aws.tokyo
  name          = "alias/cloud-duck-rds-tokyo"
  target_key_id = aws_kms_key.rds_tokyo.key_id
}

