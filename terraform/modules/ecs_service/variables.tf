variable "name" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "cpu" {
  type    = number
  default = 1024
}

variable "memory" {
  type    = number
  default = 2048
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "ecr_repository_url" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "container_port" {
  description = "컨테이너가 노출할 포트 (없으면 배치 워커처럼 포트 없는 서비스로 간주)"
  type        = number
  default     = null
}

variable "environment" {
  description = "컨테이너 환경변수 목록"
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "log_group" {
  type = string
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "launch_type" {
  description = "FARGATE 또는 null (null이면 capacity_provider_strategy 사용)"
  type        = string
  default     = null
}

variable "capacity_provider" {
  description = "launch_type이 null일 때 사용할 capacity provider (예: FARGATE_SPOT)"
  type        = string
  default     = null
}

variable "subnets" {
  type = list(string)
}

variable "security_groups" {
  type = list(string)
}

variable "assign_public_ip" {
  type    = bool
  default = false
}

variable "target_group_arn" {
  description = "로드밸런서 연결이 필요할 때만 지정 (배치 워커는 비워둠)"
  type        = string
  default     = null
}

variable "capacity_providers_dependency" {
  description = "capacity provider 등록 리소스 (depends_on용)"
  type        = any
  default     = null
}

variable "enable_autoscaling" {
  description = "Application Auto Scaling(target tracking on CPU) 활성화 여부"
  type        = bool
  default     = false
}

variable "autoscaling_min_capacity" {
  type    = number
  default = 1
}

variable "autoscaling_max_capacity" {
  type    = number
  default = 4
}

variable "autoscaling_cpu_target" {
  description = "목표 평균 CPU 사용률(%)"
  type        = number
  default     = 60
}