variable "project" {
  type = string
}

variable "name" {
  type = string
}

variable "alarm_email" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "rds_identifier" {
  description = "감시할 RDS 인스턴스 식별자 (null이면 알람 생성 안 함)"
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix — 빈 문자열이면 요청 수 알람 생성 안 함"
  type        = string
  default     = ""
}

# 운영 결정사항: CPU 80% 5분 지속
variable "cpu_threshold" {
  type    = number
  default = 80
}

variable "period_seconds" {
  type    = number
  default = 300 # 5분
}
