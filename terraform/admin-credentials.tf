############################################################
# 관리자 계정 자격증명 (web/server.js의 warmup 시드용)
#
# 코드에 기본값으로 박아두면 소스와 git 히스토리에 영구히 남아, 저장소를 볼 수 있는
# 사람은 누구나 운영 admin으로 로그인할 수 있게 된다. 그래서 비밀번호는 여기서
# 생성해 Secrets Manager에 넣고, ECS가 컨테이너 시작 시점에 주입한다.
#
# 비밀번호 확인 방법(최초 로그인 시):
#   aws secretsmanager get-secret-value --secret-id cloud-duck/admin/credentials \
#     --region ap-northeast-2 --query SecretString --output text
#
# 주의: 이 비밀번호는 terraform state에도 평문으로 들어간다(random_password의 특성).
# state 버킷 접근 권한을 가진 사람은 볼 수 있으므로, 실제 운영 계정이라면
# 최초 로그인 후 애플리케이션에서 직접 변경하는 절차를 두는 게 맞다.
# admin_password 로 직접 정해도 이 성질은 같다 — 값의 출처만 달라진다.
#
# 비밀번호를 직접 정하려면 admin_password 변수를 쓴다(아래 참고).
# 바꾼 뒤에는 태스크가 재시작돼야 반영된다 — warmup 이 부팅할 때만 시드하기 때문이다:
#   aws ecs update-service --cluster tf-cluster --service clduck-web   --force-new-deployment --region ap-northeast-2
#   aws ecs update-service --cluster tf-cluster --service clduck-admin --force-new-deployment --region ap-northeast-2
############################################################

variable "admin_email" {
  description = "관리자 계정 이메일 (warmup 시드용)"
  type        = string
  default     = "admin@cloudduck.cloud"
}

# 비밀번호를 직접 정하고 싶을 때 쓴다. 비워두면(null) 아래 random_password 를 쓴다.
#
# ⚠ 이 값을 terraform.tfvars 에 적지 말 것 — 그 파일은 git 에 추적 중이라 그대로
#   커밋되고 히스토리에 영구히 남는다(파일 상단 주석이 경계하는 바로 그 상황).
#   .gitignore 의 *.tfvars 는 이미 추적 중인 파일에는 적용되지 않는다.
#
#   둘 중 하나로 넘긴다 — google_client_secret 과 같은 방식이다:
#     secrets.auto.tfvars 에 적기   (이 파일은 gitignore 되고 추적되지 않는다)
#     $env:TF_VAR_admin_password = '...'   (PowerShell)
#
# 이 값은 시크릿이 "처음 만들어질 때"만 쓰인다. 이미 만들어져 있으면 여기 뭘 적어도
# 반영되지 않는다(아래 aws_secretsmanager_secret_version 의 ignore_changes 참고).
# 이미 있는 비밀번호를 바꾸는 방법도 거기 적어뒀다.
variable "admin_password" {
  description = "관리자 비밀번호(최초 생성 시에만 적용). 비워두면 20자 랜덤을 자동 생성한다"
  type        = string
  default     = null
  sensitive   = true

  # 직접 정할 때만 검사한다. 자동 생성(null)은 이미 20자라 검사할 이유가 없다.
  #
  # 최소 길이는 8자다. 원래 12자로 뒀다가 시연 편의를 위해 팀 결정으로 낮췄다.
  # 이 계정은 공개된 cloudduck.cloud 에서 경매 삭제까지 되는 권한이라,
  # 짧고 흔한 값(admin1234 등)은 추측당할 수 있다는 걸 알고 쓰는 것이다.
  # 실제 운영으로 넘어간다면 이 값을 먼저 바꿀 것.
  validation {
    condition     = var.admin_password == null || length(var.admin_password) >= 8
    error_message = "admin_password 는 8자 이상이어야 한다. 값을 비우면 20자 랜덤이 자동 생성된다."
  }
}

# admin_password 를 안 줬을 때 쓰는 값. 항상 만들어 두므로, 나중에 변수를 비우면
# 언제든 자동 생성 비밀번호로 되돌아간다.
resource "random_password" "admin" {
  length  = 20
  special = true
  # 앱이 이 값을 그대로 bcrypt에 넘기므로 문자 제약은 없지만,
  # 셸/JSON을 거칠 때 이스케이프 사고가 나기 쉬운 문자는 뺀다.
  override_special = "!#$%^&*()-_=+"
}

resource "aws_secretsmanager_secret" "admin" {
  name        = "${var.project}/admin/credentials"
  description = "cloud-duck 관리자 계정 (web/server.js warmup 시드)"

  # destroy 후 재구축 시 같은 이름을 바로 다시 쓸 수 있도록 복구 대기 없이 삭제.
  # (7일 대기로 두면 재구축 때 "already scheduled for deletion"으로 apply가 막힌다)
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    email = var.admin_email
    # 직접 정한 값이 있으면 그걸, 없으면 자동 생성값을 쓴다.
    # 단 이 값은 "최초 생성 시점"에만 쓰인다 — 아래 ignore_changes 참고.
    password = coalesce(var.admin_password, random_password.admin.result)
  })

  lifecycle {
    # 한 번 만들어진 뒤로는 terraform 이 이 값을 다시 쓰지 않는다.
    #
    # 왜 필요한가: admin_password 는 secrets.auto.tfvars(git 에 없음)나 환경변수로만
    # 넘어온다. 그 값을 가지고 있지 않은 팀원이 전체 apply 를 하면 coalesce 가
    # null 로 떨어져 자동 생성 비밀번호로 "조용히" 되돌아가고, 그 사람은 자기가
    # 남의 로그인을 깼다는 사실조차 모른다.
    #
    # ignore_changes 를 걸면 그 경로가 막힌다. 비밀번호를 가진 사람이 한 번 정하면
    # 이후 누가 apply 하든 값이 유지된다. 공유할 것도, 맞출 것도 없다.
    #
    # 대가: terraform 으로는 비밀번호를 못 바꾼다. secrets.auto.tfvars 를 고쳐도
    # plan 에 안 잡힌다. 바꾸려면 아래 둘 중 하나를 쓴다.
    #
    #   방법 1) 값만 직접 갱신 (권장)
    #     aws secretsmanager put-secret-value --secret-id cloud-duck/admin/credentials \
    #       --region ap-northeast-2 \
    #       --secret-string '{"email":"admin@cloudduck.cloud","password":"새비밀번호"}'
    #
    #   방법 2) terraform 이 다시 쓰게 만들기 (secrets.auto.tfvars 값을 반영하고 싶을 때)
    #     terraform apply -replace=aws_secretsmanager_secret_version.admin
    #
    # 어느 쪽이든 warmup 이 부팅할 때만 시드하므로 태스크 재시작이 필요하다:
    #   aws ecs update-service --cluster tf-cluster --service clduck-web   --force-new-deployment --region ap-northeast-2
    #   aws ecs update-service --cluster tf-cluster --service clduck-admin --force-new-deployment --region ap-northeast-2
    ignore_changes = [secret_string]
  }
}

locals {
  # 태스크 정의에 꽂을 형태. 서울에만 넣는다 —
  # 도쿄는 읽기 전용 replica라 warmup의 admin 시드(INSERT)가 어차피 항상 실패하고,
  # ECS는 같은 리전의 시크릿만 읽을 수 있어서 서울 ARN을 도쿄에 주면 태스크가 아예 안 뜬다.
  #
  # secret_version이 아니라 secret의 ARN을 써야 한다 — 이유는 oauth.tf의 locals 주석 참고.
  # (version을 참조하면 CI의 -target apply가 GetSecretValue 권한이 없어 실패한다)
  web_admin_secrets = [
    { name = "ADMIN_EMAIL", valueFrom = "${aws_secretsmanager_secret.admin.arn}:email::" },
    { name = "ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.admin.arn}:password::" },
  ]
}
