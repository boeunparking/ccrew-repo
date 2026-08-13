data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${var.name}.zip"
}

# Lambda가 자동으로 만드는 로그 그룹을 미리 선언해 보존 기간을 관리
resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_in_days
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  role             = var.role_arn
  handler          = var.handler
  runtime          = var.runtime
  timeout          = var.timeout
  memory_size      = var.memory_size
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256

  dynamic "environment" {
    for_each = length(var.environment) > 0 ? [var.environment] : []
    content {
      variables = environment.value
    }
  }

  depends_on = [aws_cloudwatch_log_group.this]
}
