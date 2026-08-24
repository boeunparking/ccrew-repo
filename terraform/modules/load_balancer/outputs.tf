output "alb_tg_arn" {
  value = aws_lb_target_group.tf_web_tg.arn
}

# HealthyHostCount / UnHealthyHostCount 는 LoadBalancer 와 TargetGroup 두 dimension 을
# 함께 줘야 나오는 지표다. CloudWatch 가 받는 형식은 전체 ARN 이 아니라 suffix 다
# (targetgroup/tf-web-tg/xxxx).
output "alb_tg_arn_suffix" {
  description = "타겟그룹 ARN suffix (CloudWatch TargetGroup dimension)"
  value       = aws_lb_target_group.tf_web_tg.arn_suffix
}

output "alb_arn_suffix" {
  value = aws_lb.tf_alb.arn_suffix
}

output "alb_arn" {
  description = "Global Accelerator 엔드포인트로 등록할 ALB 자체의 ARN"
  value       = aws_lb.tf_alb.arn
}

output "alb_dns_name" {
  value = aws_lb.tf_alb.dns_name
}

output "alb_zone_id" {
  description = "Route 53 alias 레코드에서 evaluate_target_health와 함께 쓰는 ALB 자체의 호스팅 영역 ID"
  value       = aws_lb.tf_alb.zone_id
}

output "https_listener_arn" {
  description = "경로 기반 리스너 규칙(aws_lb_listener_rule)을 추가로 붙일 때 필요"
  value       = aws_lb_listener.https.arn
}