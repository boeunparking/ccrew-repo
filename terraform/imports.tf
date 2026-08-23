# 기존에 이미 존재하는 리소스를 state로 편입시키는 import 블록.
# `terraform import` CLI는 설정 전체를 평가하다가 ACM 인증서 for_each(unknown) 에러에
# 걸려서 실패하므로, plan/apply 흐름 안에서 처리되는 import 블록을 대신 사용한다.
# apply가 끝나서 편입이 완료되면 이 파일은 삭제해도 된다.

import {
  to = aws_s3_bucket.frontend
  id = "cloud-duck-frontend-apne2"
}
