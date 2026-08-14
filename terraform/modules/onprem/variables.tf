variable "project" {
  type = string
}

variable "vpc_cidr_block" {
  description = "온프레미스 VPC CIDR (서울 172.16.0.0/16, 도쿄 172.17.0.0/16 과 겹치지 않아야 함)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr_block" {
  description = "onprem-sn1 CIDR"
  type        = string
  default     = "10.0.1.0/24"
}

variable "az_name" {
  description = "온프레미스 서브넷 AZ (서울 스택의 2a/2c 와 구분되는 2b 사용)"
  type        = string
  default     = "ap-northeast-2b"
}

variable "seoul_vpc_cidr" {
  description = "서울 VPC CIDR — SG/NACL 인바운드 허용 대상"
  type        = string
}

variable "instance_type" {
  description = "MinIO 서버 인스턴스 타입 (t4g = ARM/Graviton)"
  type        = string
  default     = "t4g.micro"
}

variable "minio_volume_size" {
  description = "MinIO 데이터(backup/, backup/pii/)용 EBS 크기 (GB)"
  type        = number
  default     = 30
}

variable "snapshot_retain_count" {
  description = "DLM 일일 스냅샷 보존 개수"
  type        = number
  default     = 7
}
