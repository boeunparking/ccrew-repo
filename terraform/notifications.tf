############################################################
# 낙찰 알림 — SES 도메인 인증
#
# "낙찰되었습니다" 메일은 수신자가 매번 다르므로(입찰 승자), 고정 구독자에게
# 보내는 SNS 토픽이 아니라 SES SendEmail(수신자를 호출 시점에 지정)이 맞는 도구다.
# route53.tf에서 이미 조회해둔 기존 cloudduck.cloud 존을 그대로 쓴다.
############################################################

resource "aws_sesv2_email_identity" "cloudduck" {
  email_identity = var.domain_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }
}

# Easy DKIM — 이 3개 CNAME을 등록해야 도메인이 검증되고 발신 서명도 활성화된다.
resource "aws_route53_record" "ses_dkim" {
  count = 3

  zone_id = data.aws_route53_zone.cloudduck.zone_id
  name    = "${aws_sesv2_email_identity.cloudduck.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.cloudduck.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

variable "ses_from_address" {
  description = "낙찰 알림 발신 주소"
  type        = string
  default     = "noreply@cloudduck.cloud"
}

############################################################
# 워커(batch) 전용 Task Role — SES 발송 권한만. web/admin과 같은
# ecs_task role을 재사용하지 않는 이유: 그쪽엔 S3/Secrets 권한이 있어서
# 워커에 굳이 그 권한까지 줄 필요가 없다 (최소 권한 원칙).
############################################################
module "worker_task" {
  source  = "./modules/iam_role"
  name    = "worker-task-role"
  service = "ecs-tasks.amazonaws.com"
}

data "aws_iam_policy_document" "worker_permissions" {
  statement {
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = [aws_sesv2_email_identity.cloudduck.arn]
  }
}

resource "aws_iam_role_policy" "worker_permissions" {
  name   = "worker-ses-send"
  role   = module.worker_task.iam_role_name
  policy = data.aws_iam_policy_document.worker_permissions.json
}
