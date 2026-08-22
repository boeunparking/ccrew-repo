########################################
# CloudFront 전용 provider (us-east-1)
# ACM 인증서는 CloudFront용이면 반드시 us-east-1에서 발급해야 함
########################################
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

########################################
# 프론트엔드 정적 파일 전용 S3 버킷
########################################
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project}-frontend-apne2"

  tags = { Name = "${var.project}-frontend" }
  
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # CloudFront OAC와 별다른 설정 없이 바로 호환
    }
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########################################
# ACM 인증서 (us-east-1, CloudFront 전용)
########################################
resource "aws_acm_certificate" "cloudfront" {
  provider          = aws.us_east_1
  domain_name       = "cloudduck.cloud"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cloudfront_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.cloudduck.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_cert_validation : r.fqdn]
}

########################################
# OAC — CloudFront만 S3에 접근 허용
########################################
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.project}-frontend-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

########################################
# CloudFront 배포
########################################
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = ["cloudduck.cloud"]

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  # 경매 이미지가 들어있는 source 버킷. 프론트 버킷과는 별개다.
  # OAC 는 origin 단위가 아니라 배포 단위로 재사용 가능해서 frontend 것을 그대로 쓴다.
  origin {
    domain_name              = module.s3.source_bucket_regional_domain_name
    origin_id                = "s3-uploads"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  # 업로드된 이미지만 source 버킷으로 보낸다.
  #
  # 패턴이 왜 "/auctions/*/*" 인가:
  #   업로드 키는 uploadRoutes.js 가 auctions/<사용자ID>/<타임스탬프-uuid>.<확장자> 로 만든다.
  #   그런데 SPA 에도 /auctions, /auctions/new, /auctions/:id 라우트가 있어서
  #   "/auctions/*" 로 잡으면 화면 이동까지 전부 S3 로 새어나간다. 그러면 없는 키를
  #   찾다가 403 이 나고, custom_error_response 가 그걸 index.html 로 되돌려서
  #   "우연히 동작"하긴 하지만 매 이동마다 헛된 S3 요청이 생긴다.
  #
  #   슬래시가 두 번 나오는 경로만 잡으면 둘이 정확히 갈린다:
  #     /auctions/new                        → 슬래시 1개, 매칭 안 됨 → SPA
  #     /auctions/42                         → 슬래시 1개, 매칭 안 됨 → SPA
  #     /auctions/<사용자ID>/<파일>.png      → 슬래시 2개, 매칭     → S3
  #
  #   주의: 나중에 /auctions/:id/bids 같은 2단계 SPA 라우트를 추가하면 이 구분이
  #   깨진다. 그때는 업로드 키 접두사를 auctions/ 가 아닌 걸로 바꾸는 게 맞다.
  ordered_cache_behavior {
    path_pattern           = "/auctions/*/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-uploads"
    viewer_protocol_policy = "redirect-to-https"

    # 이미지 키에 타임스탬프와 uuid 가 들어가서 같은 키가 다른 내용으로 바뀌지 않는다.
    # 그래서 길게 캐시해도 안전하다.
    min_ttl     = 0
    default_ttl = 86400
    max_ttl     = 31536000

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  # SPA(React/Vue 등) 라우팅 대응 — 404를 index.html로 리다이렉트
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.project}-frontend-cdn" }
}

########################################
# S3 버킷 정책 — CloudFront(OAC)만 GetObject 허용
########################################
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

########################################
# source 버킷 정책 — CloudFront(OAC)만 이미지 GetObject 허용
#
# 이 버킷은 계속 비공개다(public access block 4개 전부 true). 브라우저는 S3 를
# 직접 읽지 않고 CloudFront 를 통해서만 이미지를 받는다.
########################################
resource "aws_s3_bucket_policy" "uploads" {
  bucket = module.s3.source_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${module.s3.source_bucket_arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

########################################
# Route53 — cloudduck.cloud를 CloudFront로 연결
########################################
resource "aws_route53_record" "frontend" {
  zone_id = data.aws_route53_zone.cloudduck.zone_id
  name    = "cloudduck.cloud"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

########################################
# GitHub Actions(프론트엔드 배포 파이프라인)에서 쓸 output
########################################
output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}