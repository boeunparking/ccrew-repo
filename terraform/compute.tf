### 컴퓨트 레이어 변수 ###
# (hayun 브랜치 main.tf에 있던 변수들 - 여기로 옮김)

variable "image_tag_web" {
  type        = string
  description = "web ECR 이미지 태그 (CI/CD 파이프라인에서 전달)"
}
variable "image_tag_batch" {
  type        = string
  description = "batch ECR 이미지 태그 (CI/CD 파이프라인에서 전달)"
}

variable "certificate_arn" {
  type        = string
  description = "ALB HTTPS 리스너에 사용할 ACM 인증서 ARN"
}


### IAM Role ###

# ECS Task Execution Role - ECR에서 이미지 pull, CloudWatch Logs에 로그 쓰기
module "ecs_execution" {
  source  = "./modules/iam_role"
  name    = "ecs-execution-role"
  service = "ecs-tasks.amazonaws.com"
}
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = module.ecs_execution.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Role - S3 접근 + Secrets Manager 접근
module "ecs_task" {
  source  = "./modules/iam_role"
  name    = "ecs-task-role"
  service = "ecs-tasks.amazonaws.com"
}
resource "aws_iam_role_policy_attachment" "ecs_task_s3" {
  role       = module.ecs_task.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}
resource "aws_iam_role_policy_attachment" "ecs_task_secrets" {
  role       = module.ecs_task.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess"
}

# Lambda Execution Role - Lambda 함수가 CloudWatch Logs에 로그 남기기 위한 기본 권한
module "lambda_execution" {
  source  = "./modules/iam_role"
  name    = "lambda-execution-role"
  service = "lambda.amazonaws.com"
}
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = module.lambda_execution.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = module.lambda_execution.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}


### ALB ###
# vpc_id / security_group_id / subnet_ids 전부 region_stack(module.seoul) 출력값으로 연결

module "alb" {
  source            = "./modules/load_balancer"
  vpc_id            = module.seoul.vpc_id
  security_group_id = module.seoul.alb_sg_id
  subnet_ids        = [module.seoul.subnet_ids["pub-sn1"], module.seoul.subnet_ids["pub-sn2"]]
  certificate_arn   = var.certificate_arn
}


### ECR ###

resource "aws_ecr_repository" "tf_web_ecr" {
  name = "tf-web-ecr"
}
resource "aws_ecr_repository" "tf_batch_ecr" {
  name = "tf-batch-ecr"
}


### ECS 로그 그룹 ###

resource "aws_cloudwatch_log_group" "web" {
  name              = "/aws/ecs/web"
  retention_in_days = 1 # 1일 지난 로그는 자동 삭제
}
resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/ecs/batch"
  retention_in_days = 1 # 1일 지난 로그는 자동 삭제
}


### ECS Cluster ###

resource "aws_ecs_cluster" "tf_cluster" {
  name = "tf-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "tf_ccp" {
  cluster_name       = aws_ecs_cluster.tf_cluster.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# Task Definition - Web (Fargate)
# subnets / security_groups 전부 region_stack(module.seoul) 출력값으로 연결
module "web_service" {
  source = "./modules/ecs_service"

  name               = "clduck-web"
  cluster_id         = aws_ecs_cluster.tf_cluster.id
  cluster_name       = aws_ecs_cluster.tf_cluster.name
  ecr_repository_url = aws_ecr_repository.tf_web_ecr.repository_url
  image_tag          = var.image_tag_web
  execution_role_arn = module.ecs_execution.iam_role_arn
  task_role_arn      = module.ecs_task.iam_role_arn
  log_group          = aws_cloudwatch_log_group.web.name

  container_port = 3000
  environment = [
    { name = "ENV", value = "production" }
  ]

  desired_count                 = 2
  launch_type                   = "FARGATE"
  capacity_providers_dependency = aws_ecs_cluster_capacity_providers.tf_ccp

  target_group_arn = module.alb.alb_tg_arn

  subnets         = [module.seoul.subnet_ids["pri-sn3"], module.seoul.subnet_ids["pri-sn4"]]
  security_groups = [module.seoul.ecs_sg_id]

  enable_autoscaling       = true
  autoscaling_min_capacity = 2
  autoscaling_max_capacity = 10
  autoscaling_cpu_target   = 60
}

module "batch_service" {
  source = "./modules/ecs_service"

  name               = "clduck-batch"
  cluster_id         = aws_ecs_cluster.tf_cluster.id
  cluster_name       = aws_ecs_cluster.tf_cluster.name
  ecr_repository_url = aws_ecr_repository.tf_batch_ecr.repository_url
  image_tag          = var.image_tag_batch
  execution_role_arn = module.ecs_execution.iam_role_arn
  task_role_arn      = module.ecs_task.iam_role_arn
  log_group          = aws_cloudwatch_log_group.batch.name

  environment = [
    { name = "QUEUE_NAME", value = "batch-jobs" }
  ]

  desired_count     = 3
  capacity_provider = "FARGATE_SPOT" # launch_type 안 주면 이걸로 100% Spot 실행

  subnets         = [module.seoul.subnet_ids["pri-sn3"], module.seoul.subnet_ids["pri-sn4"]]
  security_groups = [module.seoul.ecs_sg_id]

  enable_autoscaling       = true
  autoscaling_min_capacity = 2
  autoscaling_max_capacity = 6
  autoscaling_cpu_target   = 60
}


### 로그 정리 Lambda ###
# (VPC 의존성 없어서 원본 그대로)

module "log_cleanup_execution" {
  source  = "./modules/iam_role"
  name    = "log-cleanup-lambda-role"
  service = "lambda.amazonaws.com"
}
resource "aws_iam_role_policy_attachment" "log_cleanup_basic_execution" {
  role       = module.log_cleanup_execution.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "log_cleanup_permissions" {
  role       = module.log_cleanup_execution.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

module "log_cleanup" {
  source     = "./modules/lambda_function"
  name       = "clduck-log-cleanup"
  source_dir = "${path.module}/modules/lambda/log_cleanup"
  role_arn   = module.log_cleanup_execution.iam_role_arn
  timeout    = 60

  environment = {
    RETENTION_DAYS   = "1"
    LOG_GROUP_PREFIX = "/aws/ecs/"
  }
}

resource "aws_cloudwatch_event_rule" "log_cleanup_schedule" {
  name        = "clduck-log-cleanup-schedule"
  description = "매일 새벽 2시(KST)에 오래된 로그 스트림 정리"
  # 매일 새벽 2시(KST, UTC+9) = 전날 17:00 UTC
  schedule_expression = "cron(0 17 * * ? *)"
}

resource "aws_cloudwatch_event_target" "log_cleanup_target" {
  rule = aws_cloudwatch_event_rule.log_cleanup_schedule.name
  arn  = module.log_cleanup.function_arn
}

resource "aws_lambda_permission" "allow_eventbridge_log_cleanup" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.log_cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.log_cleanup_schedule.arn
}
