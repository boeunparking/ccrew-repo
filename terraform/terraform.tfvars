# image_tag_web / image_tag_batch 는 더 이상 여기 적지 않는다.
#
# 값을 비워두면 terraform 이 ECR 에서 마지막으로 푸시된 이미지를 찾아 쓴다
# (compute.tf 의 data.aws_ecr_image 참고). CI 는 지금도 커밋 SHA 를 -var 로
# 명시해서 넘기므로 "이 커밋이 이 이미지"라는 보장은 그대로다.
#
# 예전에는 여기 태그를 적어 두고 CI 의 sync-image-tag 잡이 배포 후 이 두 줄을
# 다시 커밋해서 맞췄다. 그 잡이 성공해야만 파일과 실제가 일치했고, 실패하거나
# 사람이 그 사이에 로컬 apply 를 하면 방금 배포한 이미지가 조용히 롤백됐다.
# 적어두지 않으면 어긋날 것도 없다.
#
# 특정 버전으로 되돌리고 싶을 때만 명시한다:
#   terraform apply -var image_tag_web=<커밋SHA> -var image_tag_batch=<커밋SHA>
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

# ---- 구글 로그인 (cognito.tf, Cognito Identity Provider) ----
# client_id는 인가 URL에 실려 브라우저로 나가는 공개값이라 여기 적어도 된다.
# client_secret 은 절대 여기 적지 말 것 — 이 파일은 git에 추적 중이다.
#   CI: GitHub Actions Secrets 의 GOOGLE_CLIENT_SECRET
#       (deploy.yml 이 TF_VAR_google_client_secret 환경변수로 넘긴다. 이 파일에
#        google_client_secret 이 없으므로 TF_VAR_ 로도 충분히 이긴다)
#
# 로컬 apply: GitHub Secrets 는 값을 되읽을 수 없다(설계상 write-only).
# 대신 최초 apply 때 terraform 이 Cognito Identity Provider에 넣어둔 값을 그대로
# 꺼내 쓴다 — 같은 값이 되돌아가므로 apply 에 시크릿 변경사항이 잡히지 않는다.
#
# 아직 한 번도 apply 한 적이 없다면 구글 콘솔에서 값을 받아
# $env:TF_VAR_google_client_secret = 'GOCSPX-...' 로 직접 넣는다.
google_client_id = "759497431576-f28o4ll26bpc9bs3t2t208rfq3sb4q3g.apps.googleusercontent.com"
#
# 슬랙 id
slack_team_id    = "T0BKG31JUT0"
slack_channel_id = "C0BKSFNR14K"