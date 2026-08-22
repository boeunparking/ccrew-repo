########################################
# 멀티 프로바이더: source(서울) / destination(도쿄)
########################################
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.source, aws.destination]
    }
  }
}

########################################
# 서울: S3 Source 버킷
########################################
# force_destroy: 객체가 남아 있어도 버킷을 지운다.
#
# 이 버킷은 버저닝이 켜져 있어서(CRR 필수 조건) 일반 삭제로는 절대 안 비워진다 —
# 현재 버전을 지워도 이전 버전과 삭제 마커가 남아 BucketNotEmpty 로 destroy 가 막힌다.
# 그러면 사람이 list-object-versions 로 버전을 전부 훑어 지우는 수밖에 없다.
#
# ⚠ 켜두면 destroy 시 업로드된 경매 이미지가 전부 사라진다. 되돌릴 수 없다.
resource "aws_s3_bucket" "source" {
  provider      = aws.source
  bucket        = var.source_bucket_name
  force_destroy = true

  tags = { Name = "${var.project}-s3-source" }
}

resource "aws_s3_bucket_versioning" "source" {
  provider = aws.source
  bucket   = aws_s3_bucket.source.id

  versioning_configuration {
    status = "Enabled" # CRR 필수 조건
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  provider = aws.source
  bucket   = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.source_kms_key_id # null이면 AWS 관리형 aws/s3 키 사용
    }
    bucket_key_enabled = var.source_kms_key_id != null
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  provider = aws.source
  bucket   = aws_s3_bucket.source.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 브라우저 → S3 직접 업로드(presigned PUT)를 위한 CORS.
#
# uploadRoutes.js 는 이미지를 백엔드 컨테이너로 받지 않고 서명된 URL 만 발급한다.
# 그래서 실제 PUT 은 브라우저에서 S3 도메인으로 나가는 교차 출처 요청이 되는데,
# 버킷에 CORS 설정이 없으면 S3 가 프리플라이트를 403 으로 거절한다.
# (버킷을 공개로 만드는 것과는 무관하다 — public access block 은 그대로 4개 다 true다.)
#
# GET 은 넣지 않았다. 업로드된 이미지는 CloudFront 를 통해 같은 도메인으로 읽는 게
# 맞고, 그러면 교차 출처가 아니라서 CORS 자체가 필요 없다.
resource "aws_s3_bucket_cors_configuration" "source" {
  provider = aws.source
  count    = length(var.source_cors_origins) > 0 ? 1 : 0

  bucket = aws_s3_bucket.source.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = var.source_cors_origins
    # presigned PUT 은 Content-Type 을 서명에 포함하므로 브라우저가 그 헤더를 함께 보낸다.
    # 허용 헤더를 좁히면 그 조합을 일일이 맞춰야 해서 깨지기 쉽다.
    allowed_headers = ["*"]
    # 업로드 실패 시 응답 헤더를 프론트에서 읽을 수 있게 한다.
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# 버킷의 모든 객체 이벤트(생성/삭제 등)를 서울 리전 기본 EventBridge 버스로 보낸다.
# 이미지 모더레이션 파이프라인(EventBridge → SQS → Lambda → Rekognition)의 시작점.
resource "aws_s3_bucket_notification" "source_eventbridge" {
  provider    = aws.source
  bucket      = aws_s3_bucket.source.id
  eventbridge = true
}

########################################
# 도쿄: S3 CRR 대상 버킷
########################################
# source 버킷과 같은 이유로 force_destroy. 여기는 CRR 복제본이라 원본이 서울에 있고,
# 서울이 같이 지워지는 destroy 상황에서는 어차피 함께 사라질 사본이다.
resource "aws_s3_bucket" "destination" {
  provider      = aws.destination
  bucket        = var.destination_bucket_name
  force_destroy = true

  tags = { Name = "${var.project}-s3-crr" }
}

resource "aws_s3_bucket_versioning" "destination" {
  provider = aws.destination
  bucket   = aws_s3_bucket.destination.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "destination" {
  provider = aws.destination
  bucket   = aws_s3_bucket.destination.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########################################
# 복제용 IAM Role
########################################
data "aws_iam_policy_document" "assume" {
  provider = aws.source
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication" {
  provider           = aws.source
  name               = "${var.project}-s3-crr-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "replication" {
  provider = aws.source
  statement {
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [aws_s3_bucket.source.arn]
  }

  statement {
    actions = [
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging"
    ]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }

  statement {
    actions = [
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags"
    ]
    resources = ["${aws_s3_bucket.destination.arn}/*"]
  }
}

resource "aws_iam_role_policy" "replication" {
  provider = aws.source
  name     = "${var.project}-s3-crr-policy"
  role     = aws_iam_role.replication.id
  policy   = data.aws_iam_policy_document.replication.json
}

########################################
# CRR 규칙 (서울 → 도쿄)
########################################
resource "aws_s3_bucket_replication_configuration" "this" {
  provider = aws.source
  bucket   = aws_s3_bucket.source.id
  role     = aws_iam_role.replication.arn

  rule {
    id     = "crr-seoul-to-tokyo"
    status = "Enabled"

    filter {} # 전체 객체 복제

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.destination.arn
      storage_class = "STANDARD_IA" # DR 용도 비용 절감
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.source,
    aws_s3_bucket_versioning.destination
  ]
}
