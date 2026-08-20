variable "project" {
  type = string
}

variable "name" {
  type = string
}

variable "seoul_vpc_id" {
  description = "VGW를 부착할 서울 VPC ID"
  type        = string
}

variable "seoul_route_table_ids" {
  description = "온프레미스 대역 경로를 전파(propagate)할 서울 라우팅 테이블"
  type        = list(string)
}

variable "onprem_cidr" {
  description = "온프레미스(피어 상대) VPC CIDR — 정적 라우트 대상"
  type        = string
}

variable "customer_gateway_ip" {
  description = "온프레미스 쪽 장비(EC2)의 고정 공인 IP — Customer Gateway가 여기로 터널을 겁니다"
  type        = string
}

variable "customer_gateway_bgp_asn" {
  description = "온프레미스 측 BGP ASN (정적 라우팅만 쓰므로 실제 BGP 교환은 없음, 형식상 필요)"
  type        = number
  default     = 65000
}
