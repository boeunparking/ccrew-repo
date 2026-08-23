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

variable "certificate_arn_tokyo" {
  type        = string
  description = "도쿄 ALB HTTPS 리스너에 사용할 ACM 인증서 ARN (ACM은 리전 단위 리소스라 도쿄 리전에 별도 발급 필요)"
}

data "aws_caller_identity" "current" {}


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

# 컨테이너 시작 시점에 secrets(DB_USER/DB_PASSWORD 등)를 Secrets Manager에서 꺼내오려면
# task role이 아니라 execution role에 읽기 권한이 있어야 한다.
data "aws_iam_policy_document" "ecs_execution_read_db_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      module.rds_seoul.secret_arn,
      module.rds_tokyo_replica.secret_arn,
      # JWT 서명 키 + 소셜 로그인 client_secret(oauth.tf), 관리자 계정 시드
      # (admin-credentials.tf)는 더 이상 ECS 태스크로 주입되지 않는다 — Cognito로
      # 이전하면서 web 태스크가 필요로 하는 시크릿은 DB 자격증명뿐이다.
    ]
  }
}

resource "aws_iam_role_policy" "ecs_execution_read_db_secrets" {
  name   = "ecs-execution-read-db-secrets"
  role   = module.ecs_execution.iam_role_name
  policy = data.aws_iam_policy_document.ecs_execution_read_db_secrets.json
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

# S3 source 버킷이 이제 고객관리형 KMS 키(aws_kms_key.seoul)로 암호화되므로,
# presign PUT 서명(uploadRoutes.js)이 실제로 통하려면 s3:PutObject 권한만으로는
# 부족하고 이 키에 대한 kms:GenerateDataKey/Decrypt도 별도로 있어야 한다.
data "aws_iam_policy_document" "ecs_task_kms" {
  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [aws_kms_key.seoul.arn]
  }
}
resource "aws_iam_role_policy" "ecs_task_kms" {
  name   = "ecs-task-kms-seoul"
  role   = module.ecs_task.iam_role_name
  policy = data.aws_iam_policy_document.ecs_task_kms.json
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

# 도쿄(Warm Standby) ALB — vpc_id / security_group_id / subnet_ids는 region_stack(module.tokyo) 출력값으로 연결
module "alb_tokyo" {
  source = "./modules/load_balancer"
  providers = {
    aws = aws.tokyo
  }

  vpc_id            = module.tokyo.vpc_id
  security_group_id = module.tokyo.alb_sg_id
  subnet_ids        = [module.tokyo.subnet_ids["pub-sn1"], module.tokyo.subnet_ids["pub-sn2"]]
  certificate_arn   = var.certificate_arn_tokyo
}


### ECR ###
# ECR은 리전 단위 리소스라 도쿄에는 저장소를 새로 만들지 않고,
# 계정 단위 복제 설정으로 서울 저장소의 이미지를 도쿄 레지스트리로 그대로 복제한다.

# force_delete: 이미지가 남아 있어도 저장소를 지운다.
# 안 켜두면 destroy 가 RepositoryNotEmptyException 으로 막히고, 사람이 이미지를
# 일일이 지운 뒤 다시 destroy 해야 한다. 여기 이미지는 CI 가 커밋 SHA 로 다시
# 빌드해서 올리는 산출물이라 원본이 git 에 있고, 잃어도 복구 가능하다.
resource "aws_ecr_repository" "tf_web_ecr" {
  name         = "tf-web-ecr"
  force_delete = true
}
resource "aws_ecr_repository" "tf_batch_ecr" {
  name         = "tf-batch-ecr"
  force_delete = true
}

resource "aws_ecr_replication_configuration" "this" {
  replication_configuration {
    rule {
      destination {
        region      = var.region_tokyo
        registry_id = data.aws_caller_identity.current.account_id
      }
      repository_filter {
        filter      = "tf-"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
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

resource "aws_cloudwatch_log_group" "web_tokyo" {
  provider          = aws.tokyo
  name              = "/aws/ecs/web-tokyo"
  retention_in_days = 1
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

# 도쿄(Warm Standby) ECS 클러스터 — ECS 클러스터는 리전 단위 리소스라 별도로 생성
resource "aws_ecs_cluster" "tf_cluster_tokyo" {
  provider = aws.tokyo
  name     = "tf-cluster-tokyo"
}

resource "aws_ecs_cluster_capacity_providers" "tf_ccp_tokyo" {
  provider           = aws.tokyo
  cluster_name       = aws_ecs_cluster.tf_cluster_tokyo.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# web 이미지(tf-web-ecr)를 쓰는 서울 서비스들이 공유하는 컨테이너 설정.
#
# web_service 와 admin_service 는 같은 이미지를 띄우고(admin 은 /admin 라우트만 따로
# Spot 으로 분리한 것) 같은 app.js 를 부팅하므로 앱이 요구하는 환경변수/시크릿이 동일하다.
# 예전에 admin_service 쪽에만 DB_* 와 secrets 가 통째로 빠져 있어서, 앱이 DB_HOST 를
# 못 찾고 127.0.0.1:3306 으로 폴백해 warmup 이 ECONNREFUSED 로 계속 실패했다.
# 두 곳에 나눠 적으면 반드시 다시 어긋나므로 여기 한 곳에서만 정의한다.
locals {
  seoul_web_environment = concat([
    { name = "ENV", value = "production" },
    { name = "UPLOAD_BUCKET", value = module.s3.source_bucket_name },
    # 앱 코드는 REDIS_URL이라는 이름을 읽지만 실제 엔진은 Valkey(Redis 프로토콜 호환)다.
    # transit_encryption_enabled=true라서 TLS 스킴(rediss://)이 필수.
    { name = "REDIS_URL", value = "rediss://${module.cache_seoul.primary_endpoint}:6379" },
    # db.js가 host/port/db name을 따로 읽는다 — endpoint는 "host:port"라 그대로 못 씀.
    { name = "DB_HOST", value = module.rds_seoul.db_address },
    { name = "DB_PORT", value = "3306" },
    { name = "DB_NAME", value = "cloud_duck" },
  ], local.web_cognito_environment)

  # Cognito로 넘어오면서 JWT_SECRET/GOOGLE_CLIENT_SECRET/ADMIN_* 시크릿 주입이
  # 전부 없어졌다 — 남은 건 DB 접속 정보뿐이다.
  seoul_web_secrets = [
    { name = "DB_USER", valueFrom = "${module.rds_seoul.secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${module.rds_seoul.secret_arn}:password::" },
  ]
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
  environment    = local.seoul_web_environment
  secrets        = local.seoul_web_secrets

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

# 도쿄(Warm Standby) 웹 서비스 — 이미지는 aws_ecr_replication_configuration이 복제한
# 도쿄 리전 레지스트리(같은 저장소 이름/태그)에서 pull한다.
# IAM Role은 글로벌 리소스라 서울과 동일한 role ARN을 그대로 사용한다.
# Warm Standby: 구성도 기준 AZ(서브넷)당 1개씩 총 2개 태스크를 평상시에도 띄워두고,
# 서울 장애로 failover 되면 CPU 60% 타겟 오토스케일링이 트래픽에 맞춰 최대 10개까지 끌어올린다.
module "web_service_tokyo" {
  source = "./modules/ecs_service"
  providers = {
    aws = aws.tokyo
  }

  name               = "clduck-web-tokyo"
  cluster_id         = aws_ecs_cluster.tf_cluster_tokyo.id
  cluster_name       = aws_ecs_cluster.tf_cluster_tokyo.name
  ecr_repository_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region_tokyo}.amazonaws.com/${aws_ecr_repository.tf_web_ecr.name}"
  image_tag          = var.image_tag_web
  execution_role_arn = module.ecs_execution.iam_role_arn
  task_role_arn      = module.ecs_task.iam_role_arn
  log_group          = aws_cloudwatch_log_group.web_tokyo.name
  region             = var.region_tokyo

  container_port = 3000
  environment = concat([
    { name = "ENV", value = "production" },
    # 같은 서울 source 버킷을 그대로 씀 - CRR 대상(도쿄) 버킷은 복제 전용 읽기 사본이라
    # 새 업로드를 직접 받는 용도로는 안 씀 (양쪽에 쓰면 복제 방향이 꼬임)
    { name = "UPLOAD_BUCKET", value = module.s3.source_bucket_name },
    # 서울 Valkey를 넘어다니지 않고 도쿄 자체 Valkey를 쓴다 - failover 중에
    # 서울이 죽어도 도쿄가 서울 캐시에 의존하지 않도록.
    { name = "REDIS_URL", value = "rediss://${module.cache_tokyo.primary_endpoint}:6379" },
    # 도쿄는 읽기 전용 크로스 리전 replica라 쓰기 요청(회원가입/입찰 등)은 여기서 실패한다 —
    # GA traffic_dial이 0%로 막혀있는 것도 이 때문(globalaccelerator.tf 참고). 그래도 부팅
    # 자체는 DB_HOST 없이는 안 되므로(warmup의 SELECT 1) 접속 정보는 넣어준다.
    { name = "DB_HOST", value = module.rds_tokyo_replica.db_address },
    { name = "DB_PORT", value = "3306" },
    { name = "DB_NAME", value = "cloud_duck" },
  ], local.web_cognito_environment)
  # Cognito User Pool은 서울에만 있는 리전 리소스지만 문제 없다 — user pool id/
  # client id/domain은 시크릿이 아니라 평문 값이라 리전 복제 없이 그대로 재사용한다.
  # (토큰 검증은 인터넷으로 JWKS를 fetch하는 방식이라 애초에 리전 종속이 없다.)
  secrets = [
    { name = "DB_USER", valueFrom = "${module.rds_tokyo_replica.secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${module.rds_tokyo_replica.secret_arn}:password::" },
  ]

  desired_count                 = 2
  launch_type                   = "FARGATE"
  capacity_providers_dependency = aws_ecs_cluster_capacity_providers.tf_ccp_tokyo

  target_group_arn = module.alb_tokyo.alb_tg_arn

  subnets         = [module.tokyo.subnet_ids["pri-sn3"], module.tokyo.subnet_ids["pri-sn4"]]
  security_groups = [module.tokyo.ecs_sg_id]

  enable_autoscaling       = true
  autoscaling_min_capacity = 2
  autoscaling_max_capacity = 10
  autoscaling_cpu_target   = 60

  # 태스크가 뜨기 전에 서울 이미지가 도쿄 레지스트리로 복제되어 있어야 한다
  depends_on = [aws_ecr_replication_configuration.this]
}

# 백그라운드 워커 (FARGATE_SPOT) — HTTP 서버가 아니라 상시 폴링 루프 프로세스.
# 하는 일 2가지: (1) 마감된 경매 낙찰자에게 SES로 메일 발송 (2) 인기 상품 통계 스냅샷 갱신.
# 둘 다 Valkey를 web 서비스와의 공유 상태 저장소로 쓴다 (auctions:open 소트셋,
# auction:{id}:leader 해시, auction:popularity 소트셋 — web/src/routes에서 채움).
# 워커가 여러 대 떠도 ZREM의 원자성으로 같은 경매를 두 번 알림 보내지 않는다 (worker.js 참고).
module "batch_service" {
  source = "./modules/ecs_service"

  name               = "clduck-batch"
  cluster_id         = aws_ecs_cluster.tf_cluster.id
  cluster_name       = aws_ecs_cluster.tf_cluster.name
  ecr_repository_url = aws_ecr_repository.tf_batch_ecr.repository_url
  image_tag          = var.image_tag_batch
  execution_role_arn = module.ecs_execution.iam_role_arn
  task_role_arn      = module.worker_task.iam_role_arn
  log_group          = aws_cloudwatch_log_group.batch.name

  environment = [
    { name = "REDIS_URL", value = "rediss://${module.cache_seoul.primary_endpoint}:6379" },
    { name = "SES_FROM_ADDRESS", value = var.ses_from_address },
    { name = "POLL_INTERVAL_SECONDS", value = "30" },
    # 낙찰 메일 발송 직전 hidden_at(이미지 반려 여부)을 확인하기 위한 최소 DB 연결.
    # batch는 원래 RDS를 안 보지만, 반려 상태는 RDS에만 있고 Redis(auctions:open)에는
    # 반영되지 않으므로(web/store.js, image_moderation Lambda) 여기서 직접 확인한다.
    { name = "DB_HOST", value = module.rds_seoul.db_address },
    { name = "DB_PORT", value = "3306" },
    { name = "DB_NAME", value = "cloud_duck" },
  ]

  secrets = [
    { name = "DB_USER", valueFrom = "${module.rds_seoul.secret_arn}:username::" },
    { name = "DB_PASSWORD", valueFrom = "${module.rds_seoul.secret_arn}:password::" },
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
