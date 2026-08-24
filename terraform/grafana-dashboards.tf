############################################################
# Grafana 데이터소스 + 대시보드 (자동 프로비저닝)
#
# grafana.tf 가 만드는 것은 "워크스페이스"라는 빈 그릇까지다. 그 안의 데이터소스와
# 대시보드는 AWS API 에 아예 존재하지 않는 개념이라(Grafana 자체 HTTP API 영역)
# grafana provider 를 하나 더 써서 채운다.
#
# ── 인증 사슬 ──────────────────────────────────────────────
#   aws_grafana_workspace_service_account  (워크스페이스 안의 로봇 계정)
#     → aws_grafana_workspace_service_account_token  (그 계정의 API 토큰)
#       → provider "grafana"  (그 토큰으로 인증)
#         → grafana_data_source / grafana_dashboard
#
# ⚠ 토큰 값이 확정되지 않은 apply 는 실패한다 — CI 가 대신 처리한다.
#   provider 설정값(url/auth)이 같은 apply 에서 만들어지는 리소스를 참조하므로,
#   토큰이 아직 없거나 교체 예정이면 plan 시점에 provider 를 구성할 수 없다:
#
#     Error: the Grafana client is required for this resource.
#            Set the auth and url provider attributes
#
#   걸리는 경우는 두 가지다 — (1) 최초 구축, (2) 아래 time_rotating 이 20일마다
#   토큰을 갈아끼우는 시점. (2)는 코드를 안 건드려도 주기적으로 찾아온다.
#
#   그래서 .github/workflows/deploy.yml 의 infra 잡이 전체 plan 앞에
#   "Grafana 인증 토큰 선행 apply" 단계를 두고 토큰을 먼저 확정짓는다.
#   CI 로 배포하는 한 사람이 신경 쓸 일은 없다.
#
#   로컬에서 직접 apply 하다 위 에러를 만나면 같은 순서로 하면 된다:
#     terraform apply -target=aws_grafana_workspace_service_account_token.tf
#     terraform apply
#
# ⚠ 토큰 수명은 최대 30일이라 만료되면 대시보드 관리가 통째로 막힌다.
#   그래서 time_rotating 으로 20일마다 미리 교체한다 — 아래 replace_triggered_by 참고.
############################################################

########################################
# 1. 프로비저닝용 서비스 계정 + 토큰
########################################
resource "aws_grafana_workspace_service_account" "tf" {
  count = var.enable_grafana ? 1 : 0

  name         = "terraform-provisioner"
  grafana_role = "ADMIN" # 데이터소스 생성은 Admin 권한이 필요하다
  workspace_id = aws_grafana_workspace.this[0].id
}

# 토큰 자체에는 "언제 갱신하라"는 개념이 없다. 20일마다 값이 바뀌는 이 리소스를
# 트리거로 삼아 토큰을 강제로 재생성한다(30일 만료 전에 여유를 두고 교체).
resource "time_rotating" "grafana_token" {
  count = var.enable_grafana ? 1 : 0

  rotation_days = 20
}

resource "aws_grafana_workspace_service_account_token" "tf" {
  count = var.enable_grafana ? 1 : 0

  name               = "terraform-provisioner-token"
  service_account_id = aws_grafana_workspace_service_account.tf[0].service_account_id
  seconds_to_live    = 60 * 60 * 24 * 30 # 30일 (API 최대값)
  workspace_id       = aws_grafana_workspace.this[0].id

  lifecycle {
    replace_triggered_by = [time_rotating.grafana_token[0]]
  }
}

########################################
# 2. grafana provider
#
# enable_grafana=false 일 때도 provider 블록 자체는 평가되므로 try() 로 빈 문자열을
# 채운다. 어차피 그 경우 아래 리소스들이 count=0 이라 provider 가 호출되지 않는다.
########################################
provider "grafana" {
  url  = try("https://${aws_grafana_workspace.this[0].endpoint}", "https://localhost")
  auth = try(aws_grafana_workspace_service_account_token.tf[0].key, "")
}

########################################
# 3. CloudWatch 데이터소스
#
# authType=default: 액세스 키를 넣지 않고 워크스페이스 IAM 롤
# (cloud-duck-grafana-role, AmazonGrafanaCloudWatchAccess 첨부)을 그대로 사용한다.
#
# 리전을 서울로 고정하지만 도쿄/us-east-1 지표도 이 데이터소스 하나로 본다 —
# Grafana CloudWatch 쿼리는 패널마다 region 을 따로 지정할 수 있어서, 리전 수만큼
# 데이터소스를 만들 필요가 없다. 아래 대시보드가 그 방식으로 되어 있다.
########################################
resource "grafana_data_source" "cloudwatch" {
  count = var.enable_grafana ? 1 : 0

  type       = "cloudwatch"
  name       = "CloudWatch"
  is_default = true

  json_data_encoded = jsonencode({
    authType      = "default"
    defaultRegion = var.region_seoul
  })
}

resource "grafana_folder" "cloud_duck" {
  count = var.enable_grafana ? 1 : 0

  title = "cloud-duck"
}

########################################
# 4. 대시보드 3종
#
# JSON 을 파일로 분리하고 templatefile 로 식별자를 주입한다. 식별자를 JSON 안에
# 직접 적지 않는 이유 — ALB ARN suffix 나 Valkey 노드 ID 같은 값은 AWS 가 생성 시점에
# 정하는 것이라, 적어두면 재구축할 때마다 대시보드가 조용히 빈 그래프가 된다.
# 실제 리소스 출력값을 넘기면 그런 어긋남이 생기지 않는다.
########################################
locals {
  # 세 대시보드가 공유하는 dimension 값 묶음.
  grafana_dashboard_vars = {
    ds_uid = try(grafana_data_source.cloudwatch[0].uid, "")

    region_seoul = var.region_seoul
    region_tokyo = var.region_tokyo

    ecs_cluster_seoul = aws_ecs_cluster.tf_cluster.name
    ecs_cluster_tokyo = aws_ecs_cluster.tf_cluster_tokyo.name
    svc_web           = module.web_service.service_name
    svc_admin         = module.admin_service.service_name
    svc_batch         = module.batch_service.service_name
    svc_web_tokyo     = module.web_service_tokyo.service_name

    rds_primary       = module.rds_seoul.primary_identifier
    rds_replica_seoul = module.rds_seoul.replica_identifier
    rds_replica_tokyo = module.rds_tokyo_replica.replica_identifier

    alb_seoul = module.alb.alb_arn_suffix
    alb_tokyo = module.alb_tokyo.alb_arn_suffix
    tg_web    = module.alb.alb_tg_arn_suffix
    tg_admin  = aws_lb_target_group.admin.arn_suffix

    # 노드 단위 지표라 목록으로 넘긴다 (JSON 템플릿 안에서 for 루프로 펼침).
    valkey_seoul = module.cache_seoul.member_clusters
    valkey_tokyo = module.cache_tokyo.member_clusters

    cloudfront_id = aws_cloudfront_distribution.frontend.id
    # GA 지표의 dimension 은 ARN 전체가 아니라 마지막 UUID 조각이다.
    ga_id = element(split("/", aws_globalaccelerator_accelerator.api.id), 1)

    sqs_queue = aws_sqs_queue.image_moderation.name
    sqs_dlq   = aws_sqs_queue.image_moderation_dlq.name

    lambda_moderation  = module.image_moderation.function_name
    lambda_log_cleanup = module.log_cleanup.function_name
  }
}

resource "grafana_dashboard" "overview" {
  count = var.enable_grafana ? 1 : 0

  folder      = grafana_folder.cloud_duck[0].uid
  overwrite   = true
  config_json = templatefile("${path.module}/grafana/overview.json.tftpl", local.grafana_dashboard_vars)
}

resource "grafana_dashboard" "seoul" {
  count = var.enable_grafana ? 1 : 0

  folder      = grafana_folder.cloud_duck[0].uid
  overwrite   = true
  config_json = templatefile("${path.module}/grafana/seoul.json.tftpl", local.grafana_dashboard_vars)
}

resource "grafana_dashboard" "dr" {
  count = var.enable_grafana ? 1 : 0

  folder      = grafana_folder.cloud_duck[0].uid
  overwrite   = true
  config_json = templatefile("${path.module}/grafana/dr.json.tftpl", local.grafana_dashboard_vars)
}

output "grafana_dashboard_urls" {
  description = "Grafana 대시보드 바로가기 (enable_grafana=false면 null)"
  value = try({
    overview = "https://${aws_grafana_workspace.this[0].endpoint}/d/${grafana_dashboard.overview[0].uid}"
    seoul    = "https://${aws_grafana_workspace.this[0].endpoint}/d/${grafana_dashboard.seoul[0].uid}"
    dr       = "https://${aws_grafana_workspace.this[0].endpoint}/d/${grafana_dashboard.dr[0].uid}"
  }, null)
}
