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
############################################################

variable "admin_email" {
  description = "관리자 계정 이메일 (warmup 시드용)"
  type        = string
  default     = "admin@cloudduck.cloud"
}

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
    email    = var.admin_email
    password = random_password.admin.result
  })
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
