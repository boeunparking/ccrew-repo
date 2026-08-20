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

variable "source_kms_key_id" {
  description = "서울 source 버킷 SSE-KMS용 고객관리형 키 ARN (null이면 AWS 관리형 aws/s3 키 사용)"
  type        = string
  default     = null
}
