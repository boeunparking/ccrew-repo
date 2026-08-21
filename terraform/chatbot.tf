############################################################
# AWS Chatbot — CloudWatch 알람을 Slack으로 전달
#
# 흐름: CloudWatch 알람 → SNS(서울/도쿄) → Chatbot → Slack 채널
#
# ⚠️ 기본값 false. 켜기 전에 콘솔에서 수동 작업이 한 번 필요하다.
#
# Slack 워크스페이스 연결은 OAuth 승인이라 Terraform으로 자동화할 수 없다.
# 아래 순서로 먼저 진행한 뒤, 얻은 두 ID를 tfvars에 넣고 enable_slack_alerts=true 로 켠다.
#
#   1) AWS 콘솔 → Amazon Q Developer in chat applications (구 AWS Chatbot)
#   2) "Configure new client" → Slack 선택 → Slack 워크스페이스에서 "허용" 클릭
#   3) 승인 후 URL에 나오는 워크스페이스 ID가 slack_team_id (T로 시작, 예: T01ABC2DEF)
#   4) Slack에서 알림 받을 채널 우클릭 → "채널 세부정보 보기" → 맨 아래 채널 ID
#      (C로 시작, 예: C01ABC2DEF). 비공개 채널이면 채널에 Chatbot 앱을 먼저 초대해야 한다.
#
# 주의: Chatbot은 알림만 보내는 게 아니라 Slack에서 AWS CLI 명령을 실행할 수도 있다.
# 그래서 guardrail_policy_arns 로 읽기 전용만 허용해 둔다 — 이게 없으면 Slack 채널에
# 들어온 사람이 인프라를 변경/삭제할 수 있다.
############################################################

variable "enable_slack_alerts" {
  description = "Chatbot으로 Slack 알림 전송 여부. 콘솔에서 Slack 워크스페이스 인증을 먼저 해야 켤 수 있다"
  type        = bool
  default     = false
}

variable "slack_team_id" {
  description = "Slack 워크스페이스 ID (T로 시작). 콘솔에서 Slack 인증을 마쳐야 알 수 있다"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "알림을 받을 Slack 채널 ID (C로 시작)"
  type        = string
  default     = ""
}

# Chatbot이 알람 그래프를 그리려면 CloudWatch를 읽어야 한다.
data "aws_iam_policy_document" "chatbot_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["chatbot.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "chatbot" {
  count = var.enable_slack_alerts ? 1 : 0

  name               = "${var.project}-chatbot-role"
  assume_role_policy = data.aws_iam_policy_document.chatbot_assume.json

  tags = { Name = "${var.project}-chatbot-role" }
}

resource "aws_iam_role_policy_attachment" "chatbot_cloudwatch" {
  count = var.enable_slack_alerts ? 1 : 0

  role       = aws_iam_role.chatbot[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "alerts" {
  count = var.enable_slack_alerts ? 1 : 0

  configuration_name = "${var.project}-alerts"
  iam_role_arn       = aws_iam_role.chatbot[0].arn

  slack_team_id    = var.slack_team_id
  slack_channel_id = var.slack_channel_id

  # 서울·도쿄 알람을 한 채널에서 다 받는다. SNS는 리전 서비스라 토픽이 리전별로
  # 따로 있고, Chatbot은 여러 리전의 토픽을 동시에 구독할 수 있다.
  sns_topic_arns = [
    module.cloudwatch_seoul.sns_topic_arn,
    module.cloudwatch_tokyo.sns_topic_arn,
  ]

  # Slack에서 실행할 수 있는 AWS 명령을 읽기 전용으로 제한한다.
  # 알림만 받을 거라면 이대로 두는 게 안전하다.
  guardrail_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]

  logging_level = "ERROR"

  tags = { Name = "${var.project}-slack-alerts" }
}

output "slack_alerts_arn" {
  description = "Chatbot Slack 설정 ARN (enable_slack_alerts=false면 null)"
  value       = try(aws_chatbot_slack_channel_configuration.alerts[0].chat_configuration_arn, null)
}
