image_tag_web         = "2eb3f29b1d453b540cfdfc2c032478cf4764b0be" # PR #3 머지 후 CI가 빌드한 이미지 (DB 접속 수정 포함)
image_tag_batch       = "2eb3f29b1d453b540cfdfc2c032478cf4764b0be"
certificate_arn       = "arn:aws:acm:ap-northeast-2:033177021117:certificate/92a3fd3f-214c-48e7-ba9d-e5fa48c53ce4"
certificate_arn_tokyo = "arn:aws:acm:ap-northeast-1:033177021117:certificate/0518d7cb-9497-4af9-b6f4-7940a9edd525" # cloudduck.cloud (도쿄 리전 발급분, ISSUED)
# github_org / github_repo 는 terraform-bootstrap 으로 옮겨졌다 (GitHub OIDC/IAM 롤과 함께).
# 여기 남겨두면 "Value for undeclared variable" 경고가 난다.

vpn_server_cert_arn = "arn:aws:acm:ap-northeast-2:033177021117:certificate/bb746fa5-e2e3-4805-a31b-994ca9163258" # vpn.cloudduck.cloud
# 클라이언트 인증용 CA (CN=cloud-duck-vpn-ca, 만료 2036-08-18).
# openssl로 직접 만들어 ACM에 import한 것이라 자동 갱신되지 않는다 — 만료 전에 사람이 다시 import해야 한다.
# CA 개인키(ca.key)는 팀원 인증서를 추가 발급할 때 필요하므로 안전한 곳에 보관할 것. 유출되면 누구나 인증서를 위조할 수 있다.
vpn_client_root_cert_arn = "arn:aws:acm:ap-northeast-2:033177021117:certificate/7c1e8db5-2305-4c7f-aeec-798798128e94"
alarm_email              = "ccrewduck@gmail.com"

# ---- 소셜 로그인 (oauth.tf) ----
# 이 두 개는 인가 URL에 실려 브라우저로 나가는 공개값이라 여기 적어도 된다.
# client_secret 은 절대 여기 적지 말 것 — 이 파일은 git에 추적 중이다.
#   CI       : GitHub Actions Secrets 의 GOOGLE_CLIENT_SECRET (deploy.yml 이 -var 로 넘김)
#   로컬 apply: $env:TF_VAR_google_client_secret = 'GOCSPX-...'  ← apply 하는 창에서 설정
google_client_id   = "759497431576-f28o4ll26bpc9bs3t2t208rfq3sb4q3g.apps.googleusercontent.com"
kakao_rest_api_key = "06d67e103df91a606ae16d88df5c6b34"
