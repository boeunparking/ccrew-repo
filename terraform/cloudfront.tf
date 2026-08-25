########################################
# CloudFront 전용 provider (us-east-1)
# ACM 인증서는 CloudFront용이면 반드시 us-east-1에서 발급해야 함
########################################
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

locals {
  # 프론트의 정식 주소. 사용자가 실제로 보게 되는 주소는 항상 이것 하나다 —
  # apex(cloudduck.cloud)로 들어와도 CloudFront 가 301 로 여기로 보낸다.
  #
  # apex 는 "또 하나의 주소"가 아니라 리다이렉트 입구일 뿐이라, 아래 세 곳
  # (인증서 SAN · 배포 aliases · A 레코드)에만 등장한다. 셋 다 apex 요청이
  # CloudFront 까지 도달하게 하는 데 기술적으로 필요해서 있는 것이고,
  # Cognito 콜백이나 CORS 허용 목록에는 넣지 않는다 — 브라우저가 apex 에서
  # 앱을 띄우지 못하므로 그 출처로 요청이 나갈 일이 없다.
  #
  # var.domain_name(=cloudduck.cloud)은 계속 남지만 그건 웹 주소가 아니라
  # 호스티드 존 이름이다. 존 이름은 바꿀 수 없고, SES 발신 도메인 인증도
  # 루트 도메인에 걸린다(notifications.tf).
  frontend_host = "www.${var.domain_name}"
}

########################################
# 프론트엔드 정적 파일 전용 S3 버킷
########################################
# 다른 앱 버킷(modules/s3)과 동일하게 인프라 수명주기를 따라간다 —
# apply 로 만들어지고 destroy 로 사라진다.
#
# force_destroy: 객체가 남아 있어도 버킷을 지운다.
#
# 이 버킷은 버저닝이 켜져 있어서 일반 삭제로는 절대 안 비워진다 — 현재 버전을 지워도
# 이전 버전과 삭제 마커가 남아 BucketNotEmpty 로 destroy 가 막힌다. 그러면 사람이
# list-object-versions 로 버전을 전부 훑어 지우는 수밖에 없다. force_destroy 는
# 버전과 삭제 마커까지 전부 지우고 버킷을 없앤다.
#
# 여기 들어 있는 건 ccrew-frontend 저장소를 vite 로 빌드한 산출물이라, 원본이 git 에
# 있고 워크플로우를 한 번 돌리면 그대로 복원된다. 잃어도 되는 데이터다.
#
# ⚠ 대신 destroy 후 재구축하면 이 버킷은 비어 있는 상태로 만들어진다.
#    프론트 저장소에서 Deploy Frontend 를 한 번 돌려야 화면이 다시 뜬다
#    (별도 저장소라 이 스택의 파이프라인이 대신 올려주지 못한다).
resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.project}-frontend-apne2"
  force_destroy = true

  tags = { Name = "${var.project}-frontend" }

  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_s3_bucket_versioning" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 이전 버전 정리.
#
# 왜 필요한가: 버저닝이 켜져 있는데 배포는 매번 `s3 sync --delete` 다.
# 즉 push 할 때마다 이전 index.html 과 옛 번들이 "이전 버전"으로, 지워진 파일이
# "삭제 마커"로 남는다. 아무도 안 지우면 배포 횟수만큼 무한히 쌓인다.
# 스토리지 비용도 문제지만, force_destroy 가 destroy 때 그 버전을 전부
# 1000개씩 나눠 지워야 해서 재구축이 갈수록 느려진다.
#
# 7일인 이유: "방금 배포가 잘못됐다"를 알아채고 되돌리기에 충분한 기간이다.
# 그보다 오래 남겨둘 이유가 없다 — 원본은 ccrew-frontend 저장소에 있고
# 어느 커밋으로든 다시 빌드할 수 있다.
#
# 이 규칙은 S3 가 하루 한 번쯤 백그라운드로 돌린다. terraform apply/destroy 와는
# 무관하게 동작하므로 배포를 막거나 늦추지 않는다.
resource "aws_s3_bucket_lifecycle_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # 빈 filter = 버킷의 모든 객체. 생략하면 규칙 적용 범위가 정해지지 않는다.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  # 삭제 마커만 남고 그 아래 버전이 전부 만료된 객체를 치운다.
  # 안 켜두면 내용은 없는데 키만 영원히 남아서 목록이 지저분해진다.
  #
  # 위 규칙과 합치지 않고 따로 둔 이유: expiration 블록의 days 가 computed 라,
  # 같은 rule 안에서 noncurrent_version_expiration 과 섞으면 plan 에 매번
  # 의미 없는 변경이 잡히는 사례가 있다. 규칙 하나에 목적 하나면 그럴 일이 없다.
  rule {
    id     = "expire-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
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
  provider = aws.us_east_1

  # apex도 인증서에 있어야 한다. www만 넣으면 apex로 들어온 요청이 TLS 핸드셰이크
  # 단계에서 끊겨서, 브라우저는 301을 받아보지도 못하고 인증서 경고를 띄운다.
  domain_name               = var.domain_name
  subject_alternative_names = [local.frontend_host]
  validation_method         = "DNS"

  # SAN을 바꾸면 인증서는 교체(replace)된다. 먼저 새 인증서를 만들어 검증까지 끝낸 뒤
  # 배포에 갈아끼우고 옛 것을 지우므로 서비스가 끊기지 않는다.
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
# apex -> www 301 리다이렉트 (viewer-request)
#
# 요청이 오리진까지 가기 전에 Function 이 곧바로 301 을 돌려준다.
# S3 를 건드리지 않으므로 비용도 지연도 거의 없다.
########################################
resource "aws_cloudfront_function" "redirect_to_www" {
  name    = "${var.project}-redirect-to-www"
  runtime = "cloudfront-js-2.0"
  publish = true
  comment = "apex(${var.domain_name}) 요청을 ${local.frontend_host} 로 301 리다이렉트"

  code = templatefile("${path.module}/functions/redirect-to-www.js.tftpl", {
    frontend_host = local.frontend_host
  })
}

########################################
# CloudFront 배포
########################################
resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"

  # apex 가 여기 있어야 한다 — alias 에서 빼면 apex 요청이 CloudFront 에 도달조차
  # 못 해서(SSL 오류) 위 리다이렉트 Function 이 실행될 기회가 없다.
  aliases = [var.domain_name, local.frontend_host]

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

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

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.redirect_to_www.arn
    }

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

    # 이미지도 같은 도메인에서 나가므로 여기에도 붙인다 — 안 붙이면 apex 로 걸린
    # 이미지 URL 만 리다이렉트 없이 200 으로 응답해서 주소가 두 벌로 남는다.
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.redirect_to_www.arn
    }

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
# Route53 — apex와 www를 둘 다 CloudFront로 연결
#
# 사용자가 보게 되는 주소는 www 하나지만, apex도 같은 배포를 가리켜야 한다.
# 그래야 apex 요청이 CloudFront까지 도달해서 redirect_to_www가 301을 돌려준다.
# apex 레코드를 지우면 "리다이렉트"가 아니라 "연결 실패"가 된다.
########################################

# apex 레코드다. 이름이 frontend_www 와 짝이 맞게 "frontend_apex" 가 아닌 이유:
#
# 이미 state 에 이 주소(aws_route53_record.frontend)로 들어 있어서, 이름을 바꾸면
# moved 블록이 필요해진다. 그런데 moved 가 있으면 deploy.yml 의 ecr 잡처럼
# -target 으로 일부만 apply 하는 경로가 통째로 막힌다 —
# "Moved resource instances excluded by targeting" 으로 거부당한다.
# 이름 대칭성은 그 대가를 치를 만한 값이 아니다.
resource "aws_route53_record" "frontend" {
  zone_id = data.aws_route53_zone.cloudduck.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "frontend_www" {
  zone_id = data.aws_route53_zone.cloudduck.zone_id
  name    = local.frontend_host
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

########################################
# GitHub Actions(프론트엔드 배포 파이프라인)에서 쓸 값
#
# ccrew-frontend 저장소의 워크플로우는 "어느 버킷에 올리고 어느 배포를 무효화할지"를
# 알아야 하는데, 그 값은 여기서 만들어진다. 예전에는 사람이 아래 output 을 읽어
# GitHub Secrets 에 손으로 복사해 뒀다 — 그게 문제였다:
#
#   CloudFront 배포 ID 는 우리가 정하는 이름이 아니라 AWS 가 생성 시점에 부여하는
#   값이다. destroy 후 재구축하면 ID 가 바뀌는데 Secrets 의 복사본은 그대로다.
#   그러면 무효화 요청이 이미 없는 배포로 날아가고, 프론트 배포는 초록불인데
#   사용자에게는 옛 화면이 계속 보인다. 조용히 어긋나는 종류의 고장이다.
#
# 그래서 값을 만드는 쪽(terraform)이 SSM 에 직접 써 두고, 쓰는 쪽(프론트 워크플로우)이
# 배포 시점에 읽어간다. 사람이 옮겨 적는 단계를 없애면 어긋날 수가 없다.
# 두 저장소가 state 를 공유하지 않으므로 remote state 대신 SSM 을 경유한다.
########################################
resource "aws_ssm_parameter" "frontend_bucket_name" {
  name        = "/${var.project}/frontend/bucket_name"
  description = "프론트엔드 정적 파일 S3 버킷 (ccrew-frontend 워크플로우가 읽는다)"
  type        = "String"
  value       = aws_s3_bucket.frontend.bucket
}

resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name        = "/${var.project}/frontend/distribution_id"
  description = "프론트엔드 CloudFront 배포 ID (ccrew-frontend 워크플로우가 읽는다)"
  type        = "String"
  value       = aws_cloudfront_distribution.frontend.id
}

# 사람이 눈으로 확인할 때 쓰는 output. 배포 파이프라인은 위 SSM 을 읽으므로
# 이 값을 어딘가에 복사해 둘 필요는 없다.
output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.frontend.id
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}