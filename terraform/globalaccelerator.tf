### AWS Global Accelerator ###
# 서울(Active) + 도쿄(Warm Standby) 양쪽 ALB를 엔드포인트로 등록.
#
# 도쿄는 평상시 traffic_dial_percentage = 0으로 막아둔다 — 도쿄 RDS(rds_tokyo_replica)가
# 읽기 전용 크로스 리전 replica라서, dial을 열어두면 GA가 (서울이 멀쩡해도) 도쿄와
# 가까운 사용자를 도쿄로 proximity 라우팅해버려 쓰기 요청이 read-only 에러로 실패한다.
#
# 그래서 이 dial=0/100 값 자체는 "자동 페일오버 스위치"가 아니다 — 서울 장애 시
# 도쿄로 실제 전환하려면 (1) 이 도쿄 endpoint_group의 dial을 100으로 올리고
# (2) 도쿄 RDS를 read replica에서 쓰기 가능한 인스턴스로 promote하는 과정이 같이
# 필요하며, 이건 아직 별도 자동화(Lambda 등)로 구현되지 않았다 — 지금은 수동 대응.
#
# API 트래픽 흐름: Route53(cloudduck.cloud) -> Global Accelerator -> 서울 ALB

# resource "aws_globalaccelerator_accelerator" "api" {
#   name            = "clduck-api-accelerator"
#   ip_address_type = "IPV4"
#   enabled         = true

#   attributes {
#     flow_logs_enabled = false
#   }
# }

# # 리스너 - 443(HTTPS) 트래픽을 받아서 엔드포인트 그룹으로 분산
# # GA는 TCP/UDP 레벨에서만 동작하므로 protocol은 TCP로 지정 (TLS 종료는 ALB가 처리)
# resource "aws_globalaccelerator_listener" "api_https" {
#   accelerator_arn = aws_globalaccelerator_accelerator.api.id
#   client_affinity = "NONE"
#   protocol        = "TCP"

#   port_range {
#     from_port = 443
#     to_port   = 443
#   }
# }

# # 서울 리전 엔드포인트 그룹
# # endpoint_group_region: 이 엔드포인트 그룹이 라우팅할 리전 (엔드포인트가 실제로 위치한 리전)
# resource "aws_globalaccelerator_endpoint_group" "seoul" {
#   listener_arn          = aws_globalaccelerator_listener.api_https.id
#   endpoint_group_region = var.region_seoul

#   traffic_dial_percentage = 100 # 현재는 100% 서울로

  health_check_protocol         = "HTTPS"
  health_check_port             = 443
  health_check_path             = "/health"
  health_check_interval_seconds = 10
  threshold_count               = 3

#   endpoint_configuration {
#     endpoint_id                    = module.alb.alb_arn
#     weight                         = 100
#     client_ip_preservation_enabled = false
#   }
# }

# 도쿄 리전 엔드포인트 그룹 — module.alb_tokyo(compute.tf)가 완성되어 등록 가능해졌다.
resource "aws_globalaccelerator_endpoint_group" "tokyo" {
  listener_arn          = aws_globalaccelerator_listener.api_https.id
  endpoint_group_region = var.region_tokyo

  traffic_dial_percentage = 0 # 평상시엔 0%, 서울 장애 시 수동/자동으로 100%로 전환

  health_check_protocol         = "HTTPS"
  health_check_port             = 443
  health_check_path             = "/health"
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = module.alb_tokyo.alb_arn
    weight                         = 100
    client_ip_preservation_enabled = false
  }
}
