output "alb_tg_arn" {
  value = aws_lb_target_group.tf_web_tg.arn
}

output "alb_arn_suffix" {
  value = aws_lb.tf_alb.arn_suffix
}

output "alb_dns_name" {
  value = aws_lb.tf_alb.dns_name
}

output "alb_zone_id" {
  description = "Route 53 alias 레코드에서 evaluate_target_health와 함께 쓰는 ALB 자체의 호스팅 영역 ID"
  value       = aws_lb.tf_alb.zone_id
}