variable "project" {
  type = string
}

variable "name" {
  type = string
}

variable "region" {
  description = "대시보드 위젯이 지표를 조회할 리전. 알람/SNS는 provider를 따라가지만 대시보드 위젯은 리전을 본문에 직접 써야 한다"
  type        = string
  default     = "ap-northeast-2"
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
  description = "감시할 RDS 인스턴스 식별자"
  type        = string
  default     = null
}

# rds_identifier/alb_arn_suffix는 아직 생성되지 않은 리소스의 계산된 속성이라
# plan 시점에 값이 정해지지 않는다. count 조건은 이 값 대신 명시적 플래그로 판단한다.
variable "create_rds_alarms" {
  description = "RDS CPU/스토리지 알람 생성 여부"
  type        = bool
  default     = false
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix"
  type        = string
  default     = ""
}

variable "create_alb_alarm" {
  description = "ALB 요청 수 알람 생성 여부"
  type        = bool
  default     = false
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
