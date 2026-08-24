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

# 둘 다 채워야 VPC 안에서 뜬다 (예: RDS처럼 private 서브넷 리소스에 접근해야 하는 함수).
# 비워두면 기존처럼 AWS 관리형 네트워크에서 실행된다.
variable "subnet_ids" {
  type    = list(string)
  default = []
}

variable "security_group_ids" {
  type    = list(string)
  default = []
}
