output "alb_tg_arn" {
  value = aws_lb_target_group.tf_web_tg.arn
}

output "alb_arn_suffix" {
  value = aws_lb.tf_alb.arn_suffix
}

output "alb_arn" {
  description = "Global Accelerator 엔드포인트로 등록할 ALB 자체의 ARN"
  value       = aws_lb.tf_alb.arn
}