# 회원 관리 전체(회원가입/로그인/비밀번호/구글 연동)를 Cognito User Pool에 위임한다.
#
# 예전(oauth.tf)에는 앱이 직접 비밀번호를 해싱하고 JWT를 서명하고 구글/카카오 OAuth
# 콜백을 처리했다. 이제는 프론트가 Cognito를 직접 호출해서 토큰을 받고, web/은 그
# 토큰이 이 User Pool이 발급한 진짜 토큰인지만 검증한다(web/src/authMiddleware.js).
#
# 카카오는 완전히 뺐다 — Cognito가 기본 지원하는 소셜 로그인 공급자가 아니라 별도
# OIDC/SAML IdP로 직접 등록해야 하는데, 그 정도 수고를 들일 이유가 없다고 판단했다.
#
# User Pool은 서울에만 만드는 리전 리소스라 도쿄에 복제되지 않는다. 문제 없다 —
# aws-jwt-verify의 토큰 검증은 JWKS를 인터넷으로 fetch하는 방식이라 리전 종속이 없고,
# web 태스크는 서울/도쿄 둘 다 이미 구글 토큰 교환을 위해 인터넷 egress(NAT)를 쓰고
# 있었으므로 새로운 네트워킹 요구사항도 아니다.

variable "google_client_id" {
  description = "Google Cloud Console에서 만든 OAuth 클라이언트 ID (미설정 시 구글 버튼이 안 뜬다)"
  type        = string
  default     = ""
}

# 일부러 default를 두지 않았다 — certificate_arn과 같은 취급이다.
# 기본값을 ""로 두면, 값을 안 넘긴 apply가 조용히 성공하면서 Cognito Identity
# Provider의 client_secret을 빈 문자열로 덮어써 버린다. 없으면 apply가 아예 멈추는
# 쪽이 낫다.
#   CI      : .github/workflows/deploy.yml 이 GitHub Secrets에서 -var 로 넘긴다
#   로컬 apply: $env:TF_VAR_google_client_secret = 'GOCSPX-...'
variable "google_client_secret" {
  description = "Google OAuth 클라이언트 시크릿 (GitHub Secrets: GOOGLE_CLIENT_SECRET)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.google_client_secret) > 0
    error_message = "google_client_secret 이 비어 있다. GitHub Actions Secrets 에 GOOGLE_CLIENT_SECRET 을 등록했는지, 로컬이라면 TF_VAR_google_client_secret 을 설정했는지 확인할 것."
  }
}

resource "aws_cognito_user_pool" "this" {
  name = "${var.project}-users"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # 포트폴리오 규모 데모 계정 편의를 위해 완화했다 — admin_password 변수의 검증도
  # "8자 이상"만 본다(terraform/admin-credentials.tf). 실제 운영으로 넘어간다면
  # require_uppercase/require_symbols를 다시 켤 것.
  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = false
  }

  # schema는 풀 생성 후 사실상 불변(대부분 변경 시 풀 자체가 재생성됨)이다 —
  # 나중에 커스텀 속성이 필요해지면 풀을 통째로 다시 만들어야 한다.
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
  }

  schema {
    name                = "nickname"
    attribute_data_type = "String"
    required            = false
    mutable             = true
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # ⚠ 위 schema 블록은 이제 "최초 생성 시에만" 의미가 있다. 손대지 말 것.
  #
  # Cognito 는 스키마 항목을 추가만 할 수 있고 수정/삭제는 영구히 불가능하다.
  # nickname 은 Cognito 표준 속성이라 풀에 이미 존재하는데, provider 가 이걸
  # "config 에 있는데 풀에 없다"고 오판해 AddCustomAttributes 를 호출했고
  # (2026-08-24 12:59 실제 발생), 커스텀 속성은 무조건 custom: 접두사가 붙으므로
  # 풀에 표준 nickname 과 custom:nickname 이 동시에 생겼다.
  #
  # 그 뒤로 config(2개)와 실제 스키마(표준 + custom:nickname)가 영구히 어긋나서
  # 매 apply 마다 UpdateUserPool 을 시도하다 "cannot modify or remove schema items"
  # 로 실패했다 — 되돌릴 방법이 없으니 apply 가 통째로 막히는 상태였다.
  #
  # 실제 스키마는 이미 원하는 형태(email 필수 + nickname 존재)이고 앱이 쓰는 것도
  # 표준 nickname(구글 IdP attribute_mapping)이라 기능상 문제가 없다. custom:nickname
  # 은 아무도 참조하지 않는 잔재로 남는다 — 지우려면 풀을 재생성하는 수밖에 없다.
  #
  # 커스텀 속성이 정말 필요해지면 여기에 추가하지 말고 풀을 새로 만들 것.
  lifecycle {
    ignore_changes = [schema]
  }
}

# Google 리다이렉트(예: /oauth2/authorize?identity_provider=Google...) 처리에 필요한
# Cognito 도메인. 커스텀 도메인(auth.cloudduck.cloud 같은)은 반드시 us-east-1 ACM
# 인증서라는 새 의존성이 생겨서, 리전 프리픽스 도메인으로 충분한 규모라 이걸 쓴다.
resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.project}-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "email profile openid"
  }

  # 로그인마다 매핑값으로 갱신된다 — 사용자가 구글 쪽 이름을 바꾸면 다음 로그인 때
  # 우리 nickname도 따라 바뀐다. 의도된 동작이다.
  attribute_mapping = {
    email    = "email"
    nickname = "name"
    username = "sub"
  }

  # provider_type = "Google" 이면 Cognito 가 아래 6개 엔드포인트 필드를 자기가 채운다.
  # 우리는 코드에 안 적었으니 terraform 은 그걸 "지워야 할 값"으로 보고 매 plan 마다
  # 삭제 diff 를 만든다(provider 알려진 이슈 #4831, #24620).
  #
  # 적용해도 해결되지 않는다 — AWS 가 곧바로 같은 값을 다시 채워서 다음 plan 에 또 뜬다.
  # 실제로 이 리소스는 2026-08-24 14:56 에 업데이트됐는데도 직후 plan 에 같은 diff 가
  # 그대로 남아 있었다. 즉 장애 위험이 아니라 영구 노이즈이고, 방치하면 매 배포마다
  # 헛된 UpdateIdentityProvider 호출이 나가고 plan 에 상시 1건이 떠서 진짜 변경을 가린다.
  #
  # ⚠ ignore_changes = [provider_details] 로 통째로 막으면 안 된다.
  #   그러면 client_secret 변경까지 무시돼서, GitHub Secrets 의 GOOGLE_CLIENT_SECRET 을
  #   교체해도 terraform 이 반영하지 않고 구글 로그인이 조용히 깨진다.
  #   그래서 AWS 가 채우는 6개 키만 지목해서 무시한다 — client_id / client_secret /
  #   authorize_scopes 는 계속 추적된다.
  lifecycle {
    ignore_changes = [
      provider_details["attributes_url"],
      provider_details["attributes_url_add_attributes"],
      provider_details["authorize_url"],
      provider_details["oidc_issuer"],
      provider_details["token_request_method"],
      provider_details["token_url"],
    ]
  }
}

locals {
  # 프론트가 커스텀 로그인 폼에서 이메일/비밀번호는 SRP로 직접 처리하고, 구글
  # 버튼만 이 목록의 콜백으로 돌아온다. 로컬 개발 포트(3000/5173)는 미리 등록해뒀다 —
  # 프론트 실제 배포 주소가 늘어나면 이 목록에 추가하고 apply.
  # apex(cloudduck.cloud)는 여기 넣지 않는다. CloudFront 가 HTML 을 내려주기 전에
  # 301 로 www 로 보내기 때문에, 브라우저 주소창이 apex 인 상태로 앱이 뜨는 경우가
  # 없다 — 프론트는 location.origin 으로 redirect_uri 를 만들므로(config.js) 실제로
  # 오는 값은 항상 www 다. apex 를 등록해두면 쓰이지 않는 항목만 늘어난다.
  cognito_callback_urls = [
    "https://${local.frontend_host}/oauth/callback",
    "http://localhost:3000/oauth/callback",
    "http://localhost:5173/oauth/callback",
  ]
  cognito_logout_urls = [
    "https://${local.frontend_host}/",
    "http://localhost:3000/",
    "http://localhost:5173/",
  ]
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project}-web-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # 브라우저에서 직접 쓰는 퍼블릭 클라이언트라 secret을 안 만든다 — 만들어봤자
  # 번들에 그대로 노출되므로 시크릿로서 의미가 없다.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",      # 커스텀 로그인 폼의 이메일/비밀번호 로그인
    "ALLOW_REFRESH_TOKEN_AUTH", # 이게 없으면 60분 만료 후 재로그인 없이는 갱신 불가
  ]

  supported_identity_providers = ["COGNITO", "Google"]

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = local.cognito_callback_urls
  logout_urls   = local.cognito_logout_urls

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # Terraform이 문자열로만 "Google"을 참조해서는 이 리소스에 대한 암묵적 의존성을
  # 못 잡을 때가 있다 — 명시 안 하면 "Invalid Identity Provider: Google"로 apply가
  # 실패할 수 있다.
  depends_on = [aws_cognito_identity_provider.google]
}

# admin 그룹 멤버십이 곧 관리자 권한이다 — DB의 role 컬럼은 더 이상 안 쓴다.
# 운영자가 콘솔/CLI로 유저를 이 그룹에 넣으면(예: aws cognito-idp admin-add-user-to-group)
# 그 유저는 "재로그인 후" web/src/authMiddleware.js의 requireAdmin을 통과한다.
resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "관리자 그룹 — 여기 넣린 사용자는 다음 로그인부터 앱에서 admin으로 인식된다"
}

locals {
  # 민감정보가 아니다 — user pool id/client id/domain은 프론트 번들에도 그대로 노출되는
  # 값이라 평문 env로 넘긴다. compute.tf가 서울/도쿄 web 태스크 양쪽에 이걸 꽂는다.
  web_cognito_environment = [
    { name = "COGNITO_USER_POOL_ID", value = aws_cognito_user_pool.this.id },
    { name = "COGNITO_CLIENT_ID", value = aws_cognito_user_pool_client.web.id },
    { name = "COGNITO_REGION", value = var.region_seoul },
    { name = "COGNITO_DOMAIN", value = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region_seoul}.amazoncognito.com" },
  ]
}

########################################
# 프론트엔드 배포 파이프라인이 읽어가는 값
#
# user_pool_id / client_id 는 우리가 정하는 이름이 아니라 AWS 가 생성 시점에 부여한다.
# destroy 후 재구축하면 값이 바뀌는데, 프론트 번들에 빌드타임으로 박아 두면 그 복사본은
# 그대로 남는다 — 그러면 로그인만 조용히 깨지고 배포는 초록불이다.
# cloudfront.tf 의 bucket_name/distribution_id 와 똑같은 문제라 똑같이 푼다:
# 값을 만드는 쪽(terraform)이 SSM 에 써 두고, 쓰는 쪽(deploy.yml 의 frontend 잡)이
# 배포 시점에 읽어 dist/config.js 를 만든다.
#
# 경로를 /frontend/ 아래에 두는 이유는 권한이다 — github-actions-frontend-deploy 롤은
# parameter/cloud-duck/frontend/* 만 읽을 수 있다(terraform-bootstrap/oidc.tf).
# 다른 경로에 두면 IAM 정책도 같이 넓혀야 한다.
#
# 셋 다 브라우저 번들에 그대로 노출되는 공개값이라 SecureString 이 아니라 String 이다.
########################################
resource "aws_ssm_parameter" "frontend_cognito_user_pool_id" {
  name        = "/${var.project}/frontend/cognito_user_pool_id"
  description = "Cognito User Pool ID (프론트 배포 잡이 읽는다)"
  type        = "String"
  value       = aws_cognito_user_pool.this.id
}

resource "aws_ssm_parameter" "frontend_cognito_client_id" {
  name        = "/${var.project}/frontend/cognito_client_id"
  description = "Cognito 앱 클라이언트 ID (프론트 배포 잡이 읽는다)"
  type        = "String"
  value       = aws_cognito_user_pool_client.web.id
}

resource "aws_ssm_parameter" "frontend_cognito_domain" {
  name        = "/${var.project}/frontend/cognito_domain"
  description = "Cognito 호스팅 도메인 (구글 로그인 리다이렉트에 쓴다)"
  type        = "String"
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region_seoul}.amazoncognito.com"
}

# Google Cloud Console에 등록해야 하는 값. 지금까지(oauth.tf 시절)는 우리 백엔드
# 콜백을 등록했지만, Cognito로 오면서 Google이 코드를 돌려주는 상대는 이 고정 URI
# 하나뿐이다 — 우리 앱의 콜백은 callback_urls(위 locals)에 등록하는 것이고 구글
# 콘솔과는 무관하다.
output "cognito_google_idp_response_uri" {
  description = "Google Cloud Console > OAuth 클라이언트 > 승인된 리디렉션 URI에 등록할 값"
  value       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region_seoul}.amazoncognito.com/oauth2/idpresponse"
}

output "cognito_frontend_contract" {
  description = "프론트가 Cognito를 직접 호출할 때 필요한 값들"
  value = {
    user_pool_id                 = aws_cognito_user_pool.this.id
    client_id                    = aws_cognito_user_pool_client.web.id
    region                       = var.region_seoul
    domain                       = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${var.region_seoul}.amazoncognito.com"
    google_authorize_url_pattern = "{domain}/oauth2/authorize?identity_provider=Google&response_type=code&client_id={client_id}&redirect_uri={callback_url}&scope=openid+email+profile"
  }
}
