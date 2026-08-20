image_tag_web         = "2eb3f29b1d453b540cfdfc2c032478cf4764b0be" # PR #3 머지 후 CI가 빌드한 이미지 (DB 접속 수정 포함)
image_tag_batch       = "2eb3f29b1d453b540cfdfc2c032478cf4764b0be"
certificate_arn       = "arn:aws:acm:ap-northeast-2:033177021117:certificate/92a3fd3f-214c-48e7-ba9d-e5fa48c53ce4"
certificate_arn_tokyo = "arn:aws:acm:ap-northeast-1:033177021117:certificate/0518d7cb-9497-4af9-b6f4-7940a9edd525" # cloudduck.cloud (도쿄 리전 발급분, ISSUED)
github_org            = "boeunparking"
github_repo           = "ccrew-repo"

vpn_server_cert_arn = "arn:aws:acm:ap-northeast-2:033177021117:certificate/bb746fa5-e2e3-4805-a31b-994ca9163258" # vpn.cloudduck.cloud
# TODO: easy-rsa로 별도 CA 인증서를 만들어서 그 ARN으로 교체할 것.
# 아직 서버 인증서(3bc3bd19...)를 그대로 재사용 중이라 대기 상태 — CA 인증서 없이는 그대로 apply해도 실패함.
vpn_client_root_cert_arn = "arn:aws:acm:ap-northeast-2:033177021117:certificate/3bc3bd19-7448-474a-959a-4aeb8f0caa1e"
alarm_email              = "ccrewduck@gmail.com"
