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

variable "source_cors_origins" {
  description = <<-EOT
    source 버킷에 브라우저가 직접 PUT 할 수 있는 오리진 목록.

    web/src/routes/uploadRoutes.js 가 presigned URL 을 발급하고 브라우저가 S3 로
    직접 업로드하는 구조라, 버킷에 CORS 가 없으면 프리플라이트가 403 으로 막힌다.
    여기에 프론트 도메인을 넣지 않으면 이미지 업로드가 통째로 실패한다.
  EOT
  type        = list(string)
  default     = []
}
