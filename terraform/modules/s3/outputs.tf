output "source_bucket_arn" {
  value = aws_s3_bucket.source.arn
}

output "source_bucket_name" {
  value = aws_s3_bucket.source.bucket
}

output "destination_bucket_arn" {
  value = aws_s3_bucket.destination.arn
}
