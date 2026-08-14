variable "project" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "target_subnet_ids" {
  description = "VPN ENI를 연결할 서브넷 (DB 서브넷 tf-db-sn5, tf-db-sn6)"
  type        = list(string)
}

variable "client_cidr_block" {
  description = "VPN 클라이언트 CIDR (VPC 대역과 겹치면 안 됨)"
  type        = string
}

variable "authorized_cidrs" {
  description = "관리자에게 접근을 허용할 대상 CIDR (DB 서브넷)"
  type        = list(string)
}

variable "server_certificate_arn" {
  description = "ACM 서버 인증서 ARN"
  type        = string
}

variable "client_root_certificate_arn" {
  description = "상호 인증용 클라이언트 루트 인증서 ARN"
  type        = string
}
