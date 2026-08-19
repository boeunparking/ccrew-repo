############################################################
# 이미지 모더레이션 파이프라인
# S3(source 버킷, auctions/ 업로드) → EventBridge → SQS(+DLQ) → Lambda → Rekognition
#
# module.s3(source 버킷)에서 이미 eventbridge=true로 모든 객체 이벤트를
# 서울 리전 기본 EventBridge 버스로 보내고 있다. 여기서는 그중 auctions/
# 업로드 이벤트만 걸러서 SQS로 보내고, Lambda가 그 큐를 소비한다.
############################################################

########################################
# SQS — 버스트 완충 + 재시도/DLQ
########################################
resource "aws_sqs_queue" "image_moderation_dlq" {
  name                      = "${var.project}-image-moderation-dlq"
  message_retention_seconds = 1209600 # 14일 - 실패 원인 조사할 시간 확보
}

resource "aws_sqs_queue" "image_moderation" {
  name                       = "${var.project}-image-moderation"
  visibility_timeout_seconds = 90 # Lambda timeout(60s)보다 여유있게
  message_retention_seconds  = 86400

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.image_moderation_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "image_moderation_dlq" {
  queue_url = aws_sqs_queue.image_moderation_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.image_moderation.arn]
  })
}

# EventBridge가 이 큐로 메시지를 보낼 수 있게 허용 (발신자를 아래 규칙 하나로 한정)
data "aws_iam_policy_document" "image_moderation_queue_policy" {
  statement {
    sid       = "AllowEventBridgeSendMessage"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.image_moderation.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.auction_image_uploaded.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "image_moderation" {
  queue_url = aws_sqs_queue.image_moderation.id
  policy    = data.aws_iam_policy_document.image_moderation_queue_policy.json
}

########################################
# EventBridge — S3 이벤트 중 auctions/ 업로드만 필터링
########################################
resource "aws_cloudwatch_event_rule" "auction_image_uploaded" {
  name        = "${var.project}-auction-image-uploaded"
  description = "S3 source 버킷의 auctions/ 아래에 새 이미지가 올라오면 모더레이션 큐로 전달"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [module.s3.source_bucket_name] }
      object = { key = [{ prefix = "auctions/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "auction_image_uploaded_to_sqs" {
  rule = aws_cloudwatch_event_rule.auction_image_uploaded.name
  arn  = aws_sqs_queue.image_moderation.arn
}

########################################
# Lambda — Rekognition으로 모더레이션 후 객체 태그로 결과 기록
########################################
module "image_moderation_execution" {
  source  = "./modules/iam_role"
  name    = "image-moderation-lambda-role"
  service = "lambda.amazonaws.com"
}
resource "aws_iam_role_policy_attachment" "image_moderation_basic_execution" {
  role       = module.image_moderation_execution.iam_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "image_moderation_permissions" {
  statement {
    actions   = ["s3:GetObject", "s3:GetObjectTagging", "s3:PutObjectTagging"]
    resources = ["${module.s3.source_bucket_arn}/auctions/*"]
  }

  statement {
    actions   = ["rekognition:DetectModerationLabels"]
    resources = ["*"] # Rekognition은 리소스 레벨 권한을 지원하지 않음
  }

  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.image_moderation.arn]
  }
}

resource "aws_iam_role_policy" "image_moderation_permissions" {
  name   = "image-moderation-permissions"
  role   = module.image_moderation_execution.iam_role_name
  policy = data.aws_iam_policy_document.image_moderation_permissions.json
}

module "image_moderation" {
  source     = "./modules/lambda_function"
  name       = "clduck-image-moderation"
  source_dir = "${path.module}/modules/lambda/image_moderation"
  role_arn   = module.image_moderation_execution.iam_role_arn
  timeout    = 60

  environment = {
    MIN_CONFIDENCE = "75"
  }
}

resource "aws_lambda_event_source_mapping" "image_moderation_sqs" {
  event_source_arn        = aws_sqs_queue.image_moderation.arn
  function_name           = module.image_moderation.function_arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}
