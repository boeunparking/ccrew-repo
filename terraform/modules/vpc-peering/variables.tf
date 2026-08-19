variable "project" {
  type = string
}

variable "name" {
  description = "피어링 식별용 이름 (예: seoul-onprem)"
  type        = string
}

variable "requester_vpc_id" {
  type = string
}

variable "accepter_vpc_id" {
  type = string
}

variable "requester_vpc_cidr" {
  type = string
}

variable "accepter_vpc_cidr" {
  type = string
}

variable "accepter_region" {
  description = "크로스 리전 피어링 시 accepter 리전 (같은 리전이면 null)"
  type        = string
  default     = null
}

variable "requester_route_table_ids" {
  description = "요청자 측에서 accepter CIDR 경로를 추가할 라우트 테이블"
  type        = list(string)
}

variable "accepter_route_table_ids" {
  description = "수락자 측에서 requester CIDR 경로를 추가할 라우트 테이블"
  type        = list(string)
}
