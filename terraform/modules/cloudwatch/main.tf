########################################
# SNS 토픽 (알람 → 이메일/Slack 연동 지점)
########################################
resource "aws_sns_topic" "alarm" {
  name = "${var.project}-${var.name}-alarm"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

########################################
# ECS CPU 80% 5분 지속 (운영 결정사항)
########################################
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.project}-${var.name}-ecs-cpu-high"
  alarm_description   = "ECS CPU ${var.cpu_threshold}% 이상 5분 지속"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.cpu_threshold
  period              = var.period_seconds
  evaluation_periods  = 1

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
  ok_actions    = [aws_sns_topic.alarm.arn]
}

########################################
# ECS 메모리
########################################
resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "${var.project}-${var.name}-ecs-memory-high"
  alarm_description   = "ECS Memory 80% 이상 5분 지속"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 80
  period              = var.period_seconds
  evaluation_periods  = 1

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
}

########################################
# RDS CPU / 스토리지
########################################
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  count = var.create_rds_alarms ? 1 : 0

  alarm_name          = "${var.project}-${var.name}-rds-cpu-high"
  alarm_description   = "RDS CPU ${var.cpu_threshold}% 이상 5분 지속"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.cpu_threshold
  period              = var.period_seconds
  evaluation_periods  = 1

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  count = var.create_rds_alarms ? 1 : 0

  alarm_name          = "${var.project}-${var.name}-rds-storage-low"
  alarm_description   = "RDS 여유 스토리지 2GB 미만 (총 10GB)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024 # 2GB
  period              = var.period_seconds
  evaluation_periods  = 1

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
}

########################################
# ALB 요청 수 (Auto Scaling 기준 참고용)
########################################
resource "aws_cloudwatch_metric_alarm" "alb_requests" {
  count = var.create_alb_alarm ? 1 : 0

  alarm_name          = "${var.project}-${var.name}-alb-request-spike"
  alarm_description   = "ALB 요청 수 급증 (5분 합계 10,000건 초과)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "RequestCount"
  statistic           = "Sum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10000
  period              = var.period_seconds
  evaluation_periods  = 1

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarm.arn]
}

########################################
# 대시보드 (Grafana 연동 전 기본 뷰)
########################################
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${var.project}-${var.name}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS CPU / Memory"
          region = var.region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "RDS CPU / Connections"
          region = var.region
          stat   = "Average"
          period = 300
          metrics = var.rds_identifier != null ? [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_identifier]
          ] : []
        }
      }
    ]
  })
}
