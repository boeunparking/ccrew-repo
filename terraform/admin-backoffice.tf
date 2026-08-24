############################################################
# 관리자 백오피스 — FARGATE_SPOT 분리
##
# adminRoutes.js는 web 컨테이너 이미지 안에 이미 같이 빌드되어 있고
# (web/src/app.js가 app.use('/admin', adminRoutes) 로 마운트) 별도 이미지가
# 아니다. 그래서 코드를 건드리지 않고도 "같은 이미지를 한 벌 더, Spot으로,
# ALB 경로 라우팅만 /admin*로 걸어서" 띄우면 관리자 트래픽만 저가 용량으로
# 분리할 수 있다. 나머지 경로(/auctions, /auth 등)는 그대로 on-demand
# web_service(module.web_service)가 받는다.
#
# 내부 직원용이라 트래픽이 적고 긴급성도 낮으므로 오토스케일링 상한도 낮게 잡는다.
############################################################

resource "aws_lb_target_group" "admin" {
  name        = "tf-admin-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = module.seoul.vpc_id
  target_type = "ip"

  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener_rule" "admin" {
  listener_arn = module.alb.https_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin.arn
  }

  condition {
    path_pattern {
      values = ["/admin*"]
    }
  }
}

resource "aws_cloudwatch_log_group" "admin" {
  name              = "/aws/ecs/admin"
  retention_in_days = 1
}

module "admin_service" {
  source = "./modules/ecs_service"

  name               = "clduck-admin"
  cluster_id         = aws_ecs_cluster.tf_cluster.id
  cluster_name       = aws_ecs_cluster.tf_cluster.name
  ecr_repository_url = aws_ecr_repository.tf_web_ecr.repository_url # web과 동일한 이미지
  image_tag          = local.image_tag_web
  execution_role_arn = module.ecs_execution.iam_role_arn
  task_role_arn      = module.ecs_task.iam_role_arn
  log_group          = aws_cloudwatch_log_group.admin.name

  # web_service 와 완전히 동일한 설정을 쓴다 — 같은 이미지로 같은 app.js 를 부팅하므로
  # 앱이 요구하는 값도 같다. 정의는 compute.tf 의 locals 한 곳에만 있다.
  container_port = 3000
  environment    = local.seoul_web_environment
  secrets        = local.seoul_web_secrets

  desired_count     = 1
  capacity_provider = "FARGATE_SPOT" # launch_type 안 주면 100% Spot

  target_group_arn = aws_lb_target_group.admin.arn

  subnets         = [module.seoul.subnet_ids["pri-sn3"], module.seoul.subnet_ids["pri-sn4"]]
  security_groups = [module.seoul.ecs_sg_id]

  enable_autoscaling       = true
  autoscaling_min_capacity = 1
  autoscaling_max_capacity = 3
  autoscaling_cpu_target   = 60
}
