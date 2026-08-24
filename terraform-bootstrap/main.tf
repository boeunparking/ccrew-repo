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
#   terraform plan   # 변경사항 없어야 정상
#
# state 를 새로 시작했다면(파일이 없거나 초기화됐다면) apply 전에 아래 4개를
# 반드시 import 해야 한다. 안 하면 terraform 이 "코드엔 있는데 state 엔 없다"고
# 판단해 버킷을 새로 만들려 들고, AWS 가 409 BucketAlreadyOwnedByYou 로 막는다:
#
#   terraform import aws_s3_bucket.clduck_state ccrew-bootstrap
#   terraform import aws_s3_bucket_server_side_encryption_configuration.clduck_state ccrew-bootstrap
#   terraform import aws_s3_bucket_public_access_block.clduck_state ccrew-bootstrap
#   terraform import aws_s3_bucket_versioning.clduck_state ccrew-bootstrap
#
# 네 번째(versioning)가 예전 목록에 빠져 있어서 실제로 한 번 걸렸다 —
# 리소스를 추가하면 이 목록도 같이 늘려야 한다.
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
  bucket = "ccrew-bootstrap"

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


############################################################
# 백업 버킷 — destroy 로 사라지면 안 되는 데이터의 대피소
#
# 왜 bootstrap 에 있나: 메인 스택이 destroy 될 때 같이 사라지면 대피소 역할을
# 못 한다. 이 스택은 사람이 직접만 건드리므로 메인을 몇 번 갈아엎어도 남는다.
#
# 무엇이 들어오나 (.github/workflows/destroy.yml 이 destroy 직전에 sync):
#   uploads/<타임스탬프>/   경매 업로드 이미지 (cloud-duck-source-apne2)
#   frontend/<타임스탬프>/  프론트 정적 파일 (cloud-duck-frontend-apne2)
# 복원은 .github/workflows/restore.yml 이 가장 최근 타임스탬프를 골라서 되돌린다.
#
# 왜 "버킷을 보존"이 아니라 "복사본을 보존"인가:
#   업로드 버킷은 메인 스택의 고객관리형 KMS 키(aws_kms_key.seoul)로 암호화돼 있다.
#   버킷만 살려두고 메인을 destroy 하면 그 키가 삭제 예약(7일)에 들어가고,
#   키가 사라지는 순간 버킷은 멀쩡한데 안의 객체가 전부 영구 복호화 불가가 된다.
#   sync 로 복사하면 목적지에서 이 버킷의 키(AES256)로 다시 암호화되므로
#   원본 키의 운명과 무관해진다. 그래서 복사본 쪽이 실제로 더 안전하다.
#
# 이 버킷이 KMS 대신 AES256(SSE-S3)을 쓰는 것도 같은 이유다 —
# 대피소가 다른 스택의 키에 의존하면 대피소가 아니다.
############################################################
resource "aws_s3_bucket" "backup" {
  # S3 이름은 전역 고유라 계정 ID 를 붙인다. 이름이 계정 ID 로 결정되므로
  # 워크플로우도 SSM 조회 없이 같은 규칙으로 조립할 수 있다
  # (CloudFront 배포 ID 처럼 AWS 가 정하는 값이 아니다).
  bucket = "${local.project}-backup-${local.account_id}"

  lifecycle {
    prevent_destroy = true # 대피소를 실수로 지우면 대피의 의미가 없다
  }

  tags = { Name = "${local.project}-backup" }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# destroy 를 반복하면 타임스탬프 폴더가 계속 쌓인다. 90일이면 어떤 재구축 주기든
# 끝나고도 남는 기간이라 이 시점엔 복원할 일이 없다고 봐도 된다.
#
# ⚠ 뒤집어 말하면 90일 넘게 방치한 백업은 사라진다. 오래 보관해야 할 게 있으면
#   이 버킷 밖으로 따로 내려받을 것.
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {} # 버킷 전체

    expiration {
      days = 90
    }
  }
}

output "backup_bucket_name" {
  description = "destroy/restore 워크플로우가 쓰는 대피소 버킷"
  value       = aws_s3_bucket.backup.bucket
}
