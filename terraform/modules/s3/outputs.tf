output "source_bucket_arn" {
  value = aws_s3_bucket.source.arn
}

output "source_bucket_name" {
  value = aws_s3_bucket.source.bucket
}

output "source_bucket_id" {
  description = "aws_s3_bucket_policy 의 bucket 인자에 넣는 값"
  value       = aws_s3_bucket.source.id
}

output "source_bucket_regional_domain_name" {
  description = "CloudFront origin 의 domain_name 에 넣는 값. 리전이 포함된 형태여야 리다이렉트 없이 바로 붙는다."
  value       = aws_s3_bucket.source.bucket_regional_domain_name
}

output "destination_bucket_arn" {
  value = aws_s3_bucket.destination.arn
}
