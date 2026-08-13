variable "name" {
  type        = string
  description = "Lambda 함수 이름"
}

variable "source_dir" {
  type        = string
  description = "Lambda 소스 코드 디렉토리 경로 (zip으로 패키징됨)"
}

variable "handler" {
  type    = string
  default = "index.handler"
}

variable "runtime" {
  type    = string
  default = "python3.13"
}

variable "role_arn" {
  type        = string
  description = "Lambda 실행 역할 ARN"
}

variable "timeout" {
  type    = number
  default = 30
}

variable "memory_size" {
  type    = number
  default = 256
}

variable "environment" {
  description = "Lambda 환경변수"
  type        = map(string)
  default     = {}
}

variable "log_retention_in_days" {
  type    = number
  default = 14
}
