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
resource "aws_s3_bucket" "source" {
  provider = aws.source
  bucket   = var.source_bucket_name

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
resource "aws_s3_bucket" "destination" {
  provider = aws.destination
  bucket   = var.destination_bucket_name

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
