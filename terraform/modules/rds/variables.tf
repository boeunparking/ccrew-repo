variable "project" {
  type = string
}

variable "name" {
  description = "식별자 접미사 (예: seoul)"
  type        = string
}

variable "subnet_ids" {
  description = "DB 서브넷 (tf-db-sn5, tf-db-sn6)"
  type        = list(string)
}

variable "vpc_id" {
  type = string
}

variable "ecs_sg_id" {
  description = "3306 인바운드를 허용할 ECS 보안그룹 (tf-db-sg: TCP 3306 ← ecs_sg)"
  type        = string
}

variable "vpn_client_cidr" {
  description = "VPN 관리자 접근용 CIDR (null이면 규칙 생성 안 함)"
  type        = string
  default     = null
}

# 결정사항 반영 기본값
variable "engine_version" {
  type    = string
  default = "8.0" # MySQL 8.0
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20 # 10GB
}

variable "username" {
  type    = string
  default = "admin"
}

variable "backup_retention_period" {
  type    = number
  default = 1 # 자동 백업 보존 기간 5일
}

variable "multi_az" {
  type    = bool
  default = false # primary에서 multi_az=true
}

variable "create_primary" {
  description = "true면 primary 생성, false면 replica 전용 모듈로 동작"
  type        = bool
  default     = true
}

variable "create_replica" {
  description = "같은 리전 read replica 생성 여부"
  type        = bool
  default     = false
}

variable "replicate_source_db" {
  description = "replica 전용 모드일 때 소스 DB ARN (크로스 리전)"
  type        = string
  default     = null
}

# 소스 DB ARN은 apply 시점에야 정해지므로 count 조건으로 쓸 수 없다.
# 크로스 리전 replica 생성 여부는 이 플래그로 판단한다.
variable "create_cross_region_replica" {
  description = "크로스 리전 read replica 생성 여부"
  type        = bool
  default     = false
}

variable "primary_availability_zone" {
  description = "Primary DB AZ (구조도 기준: ap-northeast-2a)"
  type        = string
  default     = null
}

variable "replica_availability_zone" {
  description = "Read Replica AZ (구조도 기준: ap-northeast-2c)"
  type        = string
  default     = null
}

variable "kms_key_id" {
  type    = string
  default = null
}

########################################
# replica 전용 모드(create_primary=false)에서도 Secrets Manager 시크릿이 필요할 때 사용
# (예: 도쿄 크로스 리전 replica — 소스 DB와 계정정보는 동일, host만 이 리전 엔드포인트로 저장)
########################################
variable "create_secret" {
  description = "true면 create_primary=false여도 Secrets Manager 시크릿을 생성한다"
  type        = bool
  default     = false
}

variable "secret_username" {
  description = "create_secret=true, create_primary=false일 때 저장할 username (소스 DB와 동일해야 함)"
  type        = string
  default     = null
}

variable "secret_password" {
  description = "create_secret=true, create_primary=false일 때 저장할 password (소스 DB에서 전달받음)"
  type        = string
  default     = null
  sensitive   = true
}