### Route53 ###
# cloudduck.cloud 는 이미 등록된 도메인 + 이미 존재하는 호스티드 존이므로
# aws_route53_zone(생성)이 아니라 data 소스로 "조회"만 함
# notifications.tf(SES DKIM)도 이 zone/변수를 그대로 재사용한다.

variable "domain_name" {
  description = "Route 53에 이미 등록되어 있는 루트 도메인"
  type        = string
  default     = "cloudduck.cloud"
}

data "aws_route53_zone" "cloudduck" {
  name         = var.domain_name
  private_zone = false
}

# API 서브도메인 -> Global Accelerator 로 alias 연결
# 예: api.cloudduck.cloud (프론트 도메인과 달리 www를 붙이지 않는다)
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.cloudduck.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_globalaccelerator_accelerator.api.dns_name
    zone_id                = aws_globalaccelerator_accelerator.api.hosted_zone_id
    evaluate_target_health = false
  }
}