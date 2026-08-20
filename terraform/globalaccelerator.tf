### AWS Global Accelerator ###
# 현재는 서울 ALB만 엔드포인트로 등록 (도쿄 컴퓨트 레이어 미완성이라 도쿄 엔드포인트 그룹은 나중에 추가)
# API 트래픽 흐름: Route53(cloudduck.cloud) -> Global Accelerator -> 서울 ALB

resource "aws_globalaccelerator_accelerator" "api" {
  name            = "clduck-api-accelerator"
  ip_address_type = "IPV4"
  enabled         = true

  attributes {
    flow_logs_enabled = false
  }
}

# 리스너 - 443(HTTPS) 트래픽을 받아서 엔드포인트 그룹으로 분산
# GA는 TCP/UDP 레벨에서만 동작하므로 protocol은 TCP로 지정 (TLS 종료는 ALB가 처리)
resource "aws_globalaccelerator_listener" "api_https" {
  accelerator_arn = aws_globalaccelerator_accelerator.api.id
  client_affinity = "NONE"
  protocol        = "TCP"

  port_range {
    from_port = 443
    to_port   = 443
  }
}

# 서울 리전 엔드포인트 그룹
# endpoint_group_region: 이 엔드포인트 그룹이 라우팅할 리전 (엔드포인트가 실제로 위치한 리전)
resource "aws_globalaccelerator_endpoint_group" "seoul" {
  listener_arn          = aws_globalaccelerator_listener.api_https.id
  endpoint_group_region = var.region_seoul

  traffic_dial_percentage = 100 # 현재는 100% 서울로

  health_check_protocol         = "HTTPS"
  health_check_port             = 443
  health_check_path             = "/health"
  health_check_interval_seconds = 10
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = module.alb.alb_arn
    weight                         = 100
    client_ip_preservation_enabled = false
  }
}

# --- 도쿄 컴퓨트 레이어(ALB/ECS) 완성 후 아래 블록 주석 해제 ---
# resource "aws_globalaccelerator_endpoint_group" "tokyo" {
#   listener_arn          = aws_globalaccelerator_listener.api_https.id
#   endpoint_group_region = var.region_tokyo
#
#   traffic_dial_percentage = 0 # 평상시엔 0%, 서울 장애 시 수동/자동으로 100%로 전환
#
#   health_check_protocol = "HTTPS"
#   health_check_port     = 443
#   health_check_path     = "/health"
#   health_check_interval_seconds = 10
#   threshold_count        = 3
#
#   endpoint_configuration {
#     endpoint_id                    = module.alb_tokyo.alb_arn
#     weight                         = 100
#     client_ip_preservation_enabled = false
#   }
# }
