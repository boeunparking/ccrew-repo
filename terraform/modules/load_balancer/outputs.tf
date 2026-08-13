output "alb_tg_arn" {
  value = aws_lb_target_group.tf_web_tg.arn
}

output "alb_arn_suffix" {
  value = aws_lb.tf_alb.arn_suffix
}