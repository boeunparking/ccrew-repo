############################################################
# Route 53 — 서울 ALB 헬스체크 기반 Failover 라우팅
#
# 평상시: api.cloudduck.cloud -> 서울 ALB (PRIMARY)
# 서울 ALB 헬스체크(HTTPS /health) 실패 시: 자동으로 도쿄 ALB (SECONDARY)로 전환
#
# cloudduck.cloud 호스팅 영역은 이미 등록되어 있고(기존 ACM 인증서도 그 도메인으로
# DNS 검증되어 있음) 이 스택이 만든 게 아니므로, 신규 생성이 아니라 조회만 한다.
############################################################

variable "domain_name" {
  description = "Route 53에 이미 등록되어 있는 루트 도메인"
  type        = string
  default     = "cloudduck.cloud"
}

variable "api_subdomain" {
  description = "ALB로 향하는 서브도메인 라벨 (web/src/config.js의 api.cloudduck.cloud와 일치해야 함)"
  type        = string
  default     = "api"
}

locals {
  api_fqdn = "${var.api_subdomain}.${var.domain_name}"
}

data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

# 서울 ALB 헬스체크 — 이게 실패해야 Route 53이 도쿄로 failover 한다
resource "aws_route53_health_check" "seoul_alb" {
  fqdn              = module.alb.alb_dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health" # ALB 타겟그룹 헬스체크와 동일 경로
  failure_threshold = 3
  request_interval  = 30

  tags = { Name = "cloud-duck-seoul-alb-health" }
}

resource "aws_route53_record" "api_seoul_primary" {
  zone_id        = data.aws_route53_zone.primary.zone_id
  name           = local.api_fqdn
  type           = "A"
  set_identifier = "seoul-primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.seoul_alb.id

  alias {
    name                   = module.alb.alb_dns_name
    zone_id                = module.alb.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_tokyo_secondary" {
  zone_id        = data.aws_route53_zone.primary.zone_id
  name           = local.api_fqdn
  type           = "A"
  set_identifier = "tokyo-secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = module.alb_tokyo.alb_dns_name
    zone_id                = module.alb_tokyo.alb_zone_id
    evaluate_target_health = true # 도쿄 ALB/타겟그룹 자체가 unhealthy하면 이쪽도 응답하지 않도록
  }
}
