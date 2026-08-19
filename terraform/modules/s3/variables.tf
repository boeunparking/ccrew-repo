variable "project" {
  type = string
}

variable "source_bucket_name" {
  description = "서울(소스) 버킷 이름 (전역 고유)"
  type        = string
}

variable "destination_bucket_name" {
  description = "도쿄(CRR 대상) 버킷 이름 (전역 고유)"
  type        = string
}
