image_tag_web   = "3"
image_tag_batch = "3"
certificate_arn = "arn:aws:acm:ap-northeast-2:033177021117:certificate/92a3fd3f-214c-48e7-ba9d-e5fa48c53ce4"
# TODO: 도쿄(ap-northeast-1) 리전에 ACM 인증서를 별도로 발급/검증한 뒤 그 ARN으로 교체할 것.
# ACM은 리전 단위 리소스라 서울 인증서를 재사용할 수 없음 — 아래 값은 placeholder이며 그대로 apply하면 실패함.
certificate_arn_tokyo = "arn:aws:acm:ap-northeast-1:033177021117:certificate/REPLACE_ME"
github_org            = "boeunparking"
github_repo           = "ccrew-repo"

vpn_server_cert_arn      = "arn:aws:acm:ap-northeast-2:033177021117:certificate/3bc3bd19-7448-474a-959a-4aeb8f0caa1e"
vpn_client_root_cert_arn = "arn:aws:acm:ap-northeast-2:033177021117:certificate/3bc3bd19-7448-474a-959a-4aeb8f0caa1e"
alarm_email              = "ccrewduck@gmail.com"
