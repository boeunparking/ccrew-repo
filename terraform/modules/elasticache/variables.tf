variable "project" {
  type = string
}

variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "캐시를 배치할 프라이빗/DB 서브넷"
  type        = list(string)
}

variable "ecs_sg_id" {
  description = "6379 인바운드를 허용할 ECS 보안그룹"
  type        = string
}

# 결정사항: valkey, cache.t4g.micro, 3주 스코프 → 단일 노드
variable "engine" {
  type    = string
  default = "valkey"
}

variable "engine_version" {
  type    = string
  default = "8.0"
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "num_cache_clusters" {
  description = "노드 수 (단일 노드 권장 = 1)"
  type        = number
  default     = 1
}
