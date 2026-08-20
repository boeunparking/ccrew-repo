############################################################
# Bootstrap — clduck 스택이 쓰는 S3 state 버킷을 코드로 관리한다.
#
# 왜 메인 terraform/ 프로젝트 안에서 안 만드나:
#   메인 프로젝트는 이 버킷을 backend로 쓰는데, backend가 아직 없는 상태에서
#   그 backend를 만드는 리소스를 "그 backend에 저장"할 수는 없다(순환 의존성).
#   그래서 이 폴더는 완전히 별도의 로컬 state(.terraform 안에 tfstate)로 관리한다.
#
# 이 버킷은 원래 수동으로 만들어져 있던 걸 여기로 import했다 — 그래서 apply해도
# 새로 생기는 게 아니라 "이미 있는 설정 그대로"여야 정상이다 (plan에 변경사항 없어야 함).
#
# 실행 방법 (수동, CI 자동화 아님 — state 버킷은 사람이 직접 관리):
#   cd terraform-bootstrap
#   terraform init
#   terraform import aws_s3_bucket.clduck_state ccrew-033177021117-ap-northeast-2-an
#   terraform import aws_s3_bucket_server_side_encryption_configuration.clduck_state ccrew-033177021117-ap-northeast-2-an
#   terraform import aws_s3_bucket_public_access_block.clduck_state ccrew-033177021117-ap-northeast-2-an
#   terraform plan   # 변경사항 없어야 정상
############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.53.0"
    }
  }
  # 의도적으로 backend 블록 없음 — 로컬 state. 이 버킷 자체를 관리하는 state를
  # 그 버킷 안에 두면 순환 의존성이 생기고, 애초에 "사람이 직접, 가끔" 관리하는
  # 용도라 원격 backend/락이 굳이 필요하지 않다.
}

provider "aws" {
  region = "ap-northeast-2"
}

# 기존에 수동으로 만들어져 있던 버킷 — import 대상.
# 다른 팀(ccrew-tf 본체)도 같이 쓰는 공용 버킷이라 이름은 그대로 유지, clduck/ 접두사로만
# 격리해서 쓴다 (terraform/main.tf의 backend 설정 참고).
resource "aws_s3_bucket" "clduck_state" {
  bucket = "ccrew-033177021117-ap-northeast-2-an"

  lifecycle {
    prevent_destroy = true # 실수로 destroy 못 하게 — state 버킷이 사라지면 전체 인프라 관리 불능이 됨
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "clduck_state" {
  bucket = aws_s3_bucket.clduck_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "clduck_state" {
  bucket = aws_s3_bucket.clduck_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 지금 실제 버킷은 버저닝이 꺼져있다. state 파일 실수 삭제/덮어쓰기에 대비하려면
# 켜는 걸 추천하지만, import 시점엔 "있는 그대로"를 코드로 옮기는 게 우선이라
# 일단 꺼둔 채로 가져오고, 팀 확인 후 별도로 켤지 결정한다.
resource "aws_s3_bucket_versioning" "clduck_state" {
  bucket = aws_s3_bucket.clduck_state.id
  versioning_configuration {
    status = "Disabled"
  }
}
