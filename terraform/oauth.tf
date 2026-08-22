# 소셜 로그인(OAuth 2.0) + 자체 JWT 발급에 필요한 비밀값.
#
# Cognito를 쓰지 않고 앱(web/src/oauth.js)이 직접 구현하므로, 예전에 Cognito가
# 들고 있던 것들을 우리가 보관해야 한다:
#   - 공급자 client_secret (구글/카카오)
#   - 우리 서비스 JWT 서명 키
#
# client_id / REST API 키는 브라우저에 노출되는 값이라 평문 환경변수로 넘기고,
# client_secret과 JWT 키만 Secrets Manager로 넘긴다.

variable "google_client_id" {
  description = "Google Cloud Console에서 만든 OAuth 클라이언트 ID (미설정 시 구글 버튼이 안 뜬다)"
  type        = string
  default     = ""
}

# 일부러 default를 두지 않았다 — certificate_arn과 같은 취급이다.
# 기본값을 ""로 두면, 값을 안 넘긴 apply가 조용히 성공하면서 Secrets Manager의
# 실제 시크릿을 빈 문자열로 덮어써 버린다. 없으면 apply가 아예 멈추는 쪽이 낫다.
#   CI      : .github/workflows/deploy.yml 이 GitHub Secrets에서 -var 로 넘긴다
#   로컬 apply: $env:TF_VAR_google_client_secret = 'GOCSPX-...'
variable "google_client_secret" {
  description = "Google OAuth 클라이언트 시크릿 (GitHub Secrets: GOOGLE_CLIENT_SECRET)"
  type        = string
  sensitive   = true

  # GitHub Secret을 등록 안 하면 `-var "google_client_secret="` 로 빈 값이 넘어온다.
  # 변수는 "제공됨"이라 에러가 안 나고, 그대로 Secrets Manager를 빈 값으로 덮어쓴다.
  # 빈 값 자체를 거부해서 그 경로를 막는다.
  validation {
    condition     = length(var.google_client_secret) > 0
    error_message = "google_client_secret 이 비어 있다. GitHub Actions Secrets 에 GOOGLE_CLIENT_SECRET 을 등록했는지, 로컬이라면 TF_VAR_google_client_secret 을 설정했는지 확인할 것."
  }
}

variable "kakao_rest_api_key" {
  description = "카카오 개발자 콘솔의 REST API 키 (OAuth client_id로 쓰인다)"
  type        = string
  default     = ""
}

variable "kakao_client_secret" {
  description = "카카오 client_secret. 콘솔에서 '사용함'으로 켠 경우에만 채운다"
  type        = string
  default     = ""
  sensitive   = true
}

# 비워두는 게 기본이자 권장값이다. scope를 안 보내면 카카오가 개발자콘솔의
# 동의항목 설정을 그대로 적용한다 — 콘솔에서 안 켠 항목을 여기 적으면
# KOE205로 인가 요청이 통째로 실패한다.
variable "kakao_scope" {
  description = "카카오 scope 강제 지정 (기본: 콘솔 동의항목 설정을 따름)"
  type        = string
  default     = ""
}

# JWT 서명 키는 사람이 정할 이유가 없다. 여기서 만들어 Secrets Manager에만 둔다.
# 이 값이 바뀌면 이미 발급된 토큰이 전부 무효가 되므로 apply 때 갈아엎지 않도록 주의.
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

# 도쿄 태스크도 같은 키로 서명해야 서울에서 로그인한 사용자가 failover 후에도
# 그대로 인증된다. ECS는 태스크와 같은 리전의 시크릿만 읽을 수 있어서 복제본을 둔다.
resource "aws_secretsmanager_secret" "app_auth" {
  name                    = "${var.project}/app/auth"
  description             = "JWT 서명 키 + 소셜 로그인 client_secret"
  recovery_window_in_days = 0

  replica {
    region = var.region_tokyo
  }
}

resource "aws_secretsmanager_secret_version" "app_auth" {
  secret_id = aws_secretsmanager_secret.app_auth.id
  secret_string = jsonencode({
    jwt_secret           = random_password.jwt_secret.result
    google_client_secret = var.google_client_secret
    kakao_client_secret  = var.kakao_client_secret
  })
}

# 복제본 ARN은 리전 부분만 다르고 뒤의 무작위 접미사는 동일하다.
# (aws_secretsmanager_secret에 복제본 ARN을 내주는 속성이 없어서 직접 만든다)
locals {
  # 반드시 secret(껍데기)의 arn을 쓴다. secret_version의 arn을 쓰면 안 된다.
  #
  # version을 참조하면 태스크 정의의 의존성 그래프에 version 리소스가 딸려 들어가고,
  # CI(deploy.yml)의 -target apply가 그걸 refresh 하려고 GetSecretValue를 호출한다.
  # CI 롤에는 DescribeSecret/ListSecretVersionIds만 있고 GetSecretValue는 일부러 뺐다 —
  # 저장소에 푸시할 수 있는 사람이 JWT 서명 키와 client_secret을 읽어갈 수 있게 되기 때문이다.
  # 그래서 version을 참조하면 CI가 AccessDeniedException으로 통째로 실패한다.
  #
  # 대신 최초 생성 시 version보다 태스크 정의가 먼저 만들어질 수 있다. 그때는 태스크가
  # "키가 없다"로 한 번 실패하지만 ECS가 재시도하므로 결국 정상화된다.
  app_auth_secret_arn_seoul = aws_secretsmanager_secret.app_auth.arn
  app_auth_secret_arn_tokyo = replace(
    aws_secretsmanager_secret.app_auth.arn,
    var.region_seoul,
    var.region_tokyo,
  )

  # ECS 태스크 정의에 그대로 꽂는 형태. ":키::" 는 JSON에서 그 키만 꺼내라는 뜻이다.
  #
  # 목록을 var 값에 따라 늘렸다 줄였다 하지 않는 게 중요하다. CI(deploy.yml)는
  # -target으로 태스크 정의만 apply하는데, 그때 var가 비어 있으면 항목이 통째로
  # 빠진 태스크 정의가 배포되면서 소셜 로그인이 조용히 죽는다.
  # 값이 비어 있어도 JSON 키 자체는 존재하므로(아래 jsonencode) 컨테이너 기동은 정상이고,
  # 앱은 빈 client_secret을 "설정 안 됨"으로 알아서 처리한다.
  web_auth_secrets_seoul = [
    { name = "JWT_SECRET", valueFrom = "${local.app_auth_secret_arn_seoul}:jwt_secret::" },
    { name = "GOOGLE_CLIENT_SECRET", valueFrom = "${local.app_auth_secret_arn_seoul}:google_client_secret::" },
    { name = "KAKAO_CLIENT_SECRET", valueFrom = "${local.app_auth_secret_arn_seoul}:kakao_client_secret::" },
  ]

  web_auth_secrets_tokyo = [
    for s in local.web_auth_secrets_seoul : {
      name      = s.name
      valueFrom = replace(s.valueFrom, var.region_seoul, var.region_tokyo)
    }
  ]

  # 평문으로 넘겨도 되는 값들. client_id는 어차피 인가 요청 URL에 실려 브라우저로 나간다.
  web_oauth_environment = [
    { name = "GOOGLE_CLIENT_ID", value = var.google_client_id },
    { name = "KAKAO_REST_API_KEY", value = var.kakao_rest_api_key },
    { name = "KAKAO_SCOPE", value = var.kakao_scope },
    # redirect_uri와 로그인 후 복귀 주소. 공급자 콘솔 등록값과 정확히 일치해야 한다.
    { name = "PUBLIC_API_BASE_URL", value = "https://api.${var.domain_name}" },
    { name = "FRONTEND_BASE_URL", value = "https://${var.domain_name}" },
  ]
}

output "oauth_redirect_uris" {
  description = "구글/카카오 콘솔에 등록해야 하는 Redirect URI"
  value = [
    "https://api.${var.domain_name}/auth/oauth/google/callback",
    "https://api.${var.domain_name}/auth/oauth/kakao/callback",
  ]
}
