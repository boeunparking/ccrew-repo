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
  default     = true
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

  name        = "${var.project}-grafana-0"
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

########################################
# 워크스페이스 접근 권한 — IAM Identity Center 그룹 배정
#
# 워크스페이스를 만드는 것과 "누가 들어갈 수 있는가"는 별개다. 배정이 없으면
# 워크스페이스는 ACTIVE 인데 아무도 로그인할 수 없다(빈 permissions 상태).
#
# 그룹 ID 를 직접 적지 않고 이름으로 조회하는 이유: ID 는 Identity Center 를
# 다시 만들면 바뀌는 값이라 적어두면 조용히 썩는다. 이름으로 찾으면 그룹이
# 없어졌을 때 apply 가 명확한 에러로 멈춘다.
#
# ⚠ 비용: Grafana 는 "배정된 사용자 수 × 월 정액"이다(Admin/Editor 약 $9, Viewer 약 $5).
# 이 그룹에 사람을 넣는 만큼 매달 과금되므로, 그룹 멤버는 필요한 인원만 유지할 것.
########################################

variable "grafana_admin_group" {
  description = "Grafana Admin 권한을 줄 IAM Identity Center 그룹 이름"
  type        = string
  default     = "admin"
}

data "aws_ssoadmin_instances" "this" {
  count = var.enable_grafana ? 1 : 0
}

data "aws_identitystore_group" "grafana_admin" {
  count = var.enable_grafana ? 1 : 0

  identity_store_id = tolist(data.aws_ssoadmin_instances.this[0].identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = var.grafana_admin_group
    }
  }
}

# role = ADMIN: 대시보드 생성/편집 + 데이터소스 설정까지 가능.
# 조회만 시킬 사람은 별도 그룹을 만들어 role = VIEWER 로 따로 배정하는 게 맞다
# (Viewer 가 월 정액도 더 싸다).
resource "aws_grafana_role_association" "admin_group" {
  count = var.enable_grafana ? 1 : 0

  workspace_id = aws_grafana_workspace.this[0].id
  role         = "ADMIN"
  group_ids    = [data.aws_identitystore_group.grafana_admin[0].group_id]
}

output "grafana_workspace_endpoint" {
  description = "Grafana 접속 주소 (enable_grafana=false면 null)"
  value       = try(aws_grafana_workspace.this[0].endpoint, null)
}
