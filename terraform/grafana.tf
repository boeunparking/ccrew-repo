############################################################
# Amazon Managed Grafana (AMG)
#
# ⚠️ 기본값 false — 켜기 전에 반드시 읽을 것.
#
# 비용 구조가 다른 리소스와 다르다: 시간당 과금이 아니라 "사용자 수 × 월 정액"이다.
# (Editor/Admin 1인당, Viewer 1인당 각각 월 단위로 붙는다.) 워크스페이스를 만들어두고
# 아무도 안 써도 사용자가 배정돼 있으면 요금이 나가고, 하루만 켰다 꺼도 그 달치가
# 청구될 수 있다. 그래서 테스트 apply에서는 꺼두고, 시연/운영 시점에만 켜는 걸 전제로 한다.
#
#   활성화: terraform.tfvars 에  enable_grafana = true
#
# 선행 조건 (켜기 전에 확인):
#   authentication_providers = ["AWS_SSO"] 이므로 계정에 IAM Identity Center가
#   활성화되어 있어야 한다. 안 켜져 있으면 apply가 실패한다.
#   (Identity Center를 쓸 수 없는 상황이면 SAML로 바꿔야 하고, 그건 별도 IdP 설정이 필요하다.)
############################################################

variable "enable_grafana" {
  description = "Amazon Managed Grafana 워크스페이스 생성 여부. 사용자 수 기반 정액 과금이라 기본은 끔"
  type        = bool
  default     = false
}

# Grafana가 CloudWatch 지표/로그를 읽을 때 사용할 역할.
# permission_type = CUSTOMER_MANAGED 이므로 이 역할을 직접 만들어 넘긴다
# (SERVICE_MANAGED로 두면 AWS가 알아서 만들지만, 권한 범위가 코드에 안 남아서 명시적으로 관리한다).
data "aws_iam_policy_document" "grafana_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["grafana.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "grafana" {
  count = var.enable_grafana ? 1 : 0

  name               = "${var.project}-grafana-role"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume.json

  tags = { Name = "${var.project}-grafana-role" }
}

# CloudWatch 지표·로그·알람 조회 권한. AWS 관리형 정책이라 CloudWatch에 새 API가
# 생겨도 따라온다 — 직접 나열하면 그때마다 "권한 없음"으로 대시보드가 비는 일이 생긴다.
resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  count = var.enable_grafana ? 1 : 0

  role       = aws_iam_role.grafana[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonGrafanaCloudWatchAccess"
}

resource "aws_grafana_workspace" "this" {
  count = var.enable_grafana ? 1 : 0

  name        = "${var.project}-grafana"
  description = "cloud-duck 서울/도쿄 CloudWatch 지표 통합 대시보드"

  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana[0].arn

  # CloudWatch만 연결한다. 서울·도쿄 양쪽 지표를 한 워크스페이스에서 볼 수 있다
  # (Grafana 데이터소스에서 리전을 골라 조회하는 방식이라 리전별로 만들 필요 없음).
  data_sources = ["CLOUDWATCH"]

  tags = { Name = "${var.project}-grafana" }
}

output "grafana_workspace_endpoint" {
  description = "Grafana 접속 주소 (enable_grafana=false면 null)"
  value       = try(aws_grafana_workspace.this[0].endpoint, null)
}
