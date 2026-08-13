output "service_name" {
  value = aws_ecs_service.tf_task_service.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.tf_task.arn
}