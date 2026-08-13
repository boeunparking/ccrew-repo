resource "aws_ecs_task_definition" "tf_task" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([
    {
      name  = var.name
      image = "${var.ecr_repository_url}:${var.image_tag}"

      # container_port가 지정된 경우에만 portMappings 포함
      portMappings = var.container_port == null ? [] : [
        {
          containerPort = var.container_port
          hostPort      = var.container_port
          protocol      = "tcp"
        }
      ]

      environment = var.environment

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = var.log_group
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = var.name
        }
      }
    }
  ])
}

resource "aws_ecs_service" "tf_task_service" {
  name            = var.name
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.tf_task.arn
  desired_count   = var.desired_count

  # launch_type이 지정되면 그걸 쓰고, 아니면 capacity_provider_strategy 사용
  launch_type = var.launch_type

  dynamic "capacity_provider_strategy" {
    for_each = var.launch_type == null ? [1] : []
    content {
      capacity_provider = var.capacity_provider
      weight            = 1
    }
  }

  network_configuration {
    subnets          = var.subnets
    security_groups  = var.security_groups
    assign_public_ip = var.assign_public_ip
  }


  # target_group_arn이 있을 때만 load_balancer 블록 생성 (배치 워커는 자동으로 생략됨)
  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  depends_on = [var.capacity_providers_dependency]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "tf_task" {
  count              = var.enable_autoscaling ? 1 : 0
  max_capacity       = var.autoscaling_max_capacity
  min_capacity       = var.autoscaling_min_capacity
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.tf_task_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "tf_task_cpu" {
  count              = var.enable_autoscaling ? 1 : 0
  name               = "${var.name}-cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.tf_task[0].resource_id
  scalable_dimension = aws_appautoscaling_target.tf_task[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.tf_task[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = var.autoscaling_cpu_target
  }
}