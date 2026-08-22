# ECR에 실제로 존재하는 태그여야 한다. 없는 태그를 넣으면 태스크 정의는 등록되지만
# ECS가 이미지를 못 받아 CannotPullContainerError 로 계속 죽는다.
#   확인: aws ecr list-images --repository-name tf-web-ecr --region ap-northeast-2 --query "imageIds[].imageTag" --output text
#
# CI(deploy.yml)는 이 값을 안 읽고 커밋 SHA를 -var 로 직접 넘긴다. 즉 CI가 배포하면
# 실제 떠 있는 이미지와 이 파일이 어긋난다 — 그 상태로 로컬에서 전체 apply를 하면
# 이미지가 옛 버전으로 되돌아간다.
#
# 그래서 deploy.yml 의 sync-image-tag 잡이 배포 성공 후 이 두 줄을 자동으로 갱신하고
# main 에 커밋한다. 이 워크플로우의 트리거 경로는 web/** 와 batch/** 뿐이라
# 이 파일만 바뀐 커밋은 워크플로우를 다시 부르지 않는다(무한 루프 없음).
# 즉 평소엔 손댈 일이 없고, CI 없이 로컬에서만 배포할 때만 직접 맞춘다.
image_tag_web         = "622fb8a2665e618db9123f17b09c99c6dd2cbd05"
image_tag_batch       = "622fb8a2665e618db9123f17b09c99c6dd2cbd05"
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
#   CI: GitHub Actions Secrets 의 GOOGLE_CLIENT_SECRET (deploy.yml 이 -var 로 넘김)
#
# 로컬 apply: GitHub Secrets 는 값을 되읽을 수 없다(설계상 write-only).
# 대신 최초 apply 때 terraform 이 Secrets Manager 에 넣어둔 값을 그대로 꺼내 쓴다 —
# 같은 값이 되돌아가므로 apply 에 시크릿 변경사항이 잡히지 않는다.
#
#   $env:TF_VAR_google_client_secret = (aws secretsmanager get-secret-value `
#     --secret-id cloud-duck/app/auth --region ap-northeast-2 `
#     --query "SecretString" --output text | ConvertFrom-Json).google_client_secret
#
# 아직 한 번도 apply 한 적이 없다면 이 방법이 안 되므로, 구글 콘솔에서 값을 받아
# $env:TF_VAR_google_client_secret = 'GOCSPX-...' 로 직접 넣는다.
google_client_id   = "759497431576-f28o4ll26bpc9bs3t2t208rfq3sb4q3g.apps.googleusercontent.com"
kakao_rest_api_key = "06d67e103df91a606ae16d88df5c6b34"
