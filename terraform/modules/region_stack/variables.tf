variable "region" {
  description = "AWS 리전"
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR 블록 (/16)"
  type        = string
}

variable "pjt_prefix" {
  description = "리소스 이름에 붙는 접두사 (예: seoul, tokyo)"
  type        = string
}

variable "subnets" {
  description = "서브넷 정의 (CIDR, AZ, tier). pub 2개 / ecs 2개 / db 2개가 각각 /23으로 이어붙는 구조를 가정함"
  type = map(object({
    cidr = string
    az   = string
    tier = string
  }))
}
