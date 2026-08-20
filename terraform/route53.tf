### Route53 ###
# cloudduck.cloud 는 이미 등록된 도메인 + 이미 존재하는 호스티드 존이므로
# aws_route53_zone(생성)이 아니라 data 소스로 "조회"만 함

data "aws_route53_zone" "cloudduck" {
  name         = "cloudduck.cloud"
  private_zone = false
}

# API 서브도메인 -> Global Accelerator 로 alias 연결
# 예: api.cloudduck.cloud
# resource "aws_route53_record" "api" {
#   zone_id = data.aws_route53_zone.cloudduck.zone_id
#   name    = "api.cloudduck.cloud"
#   type    = "A"

#   alias {
#     name                   = aws_globalaccelerator_accelerator.api.dns_name
#     zone_id                = aws_globalaccelerator_accelerator.api.hosted_zone_id
#     evaluate_target_health = false
#   }
# }
