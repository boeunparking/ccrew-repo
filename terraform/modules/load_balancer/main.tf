// ALB 생성
resource "aws_lb" "tf_alb" {
  name                       = "tf-alb"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = var.subnet_ids
  security_groups            = [var.security_group_id]

  enable_deletion_protection = false
}

// 대상 그룹 생성
resource "aws_lb_target_group" "tf_web_tg" {
  name     = "tf-web-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  target_type = "ip" # Fargate는 반드시 ip 타입

  health_check {
    path = "/health"
  }
}

// 리스너 생성 - HTTP(80) → HTTPS(443) 리다이렉트
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.tf_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.tf_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tf_web_tg.arn
  }
}