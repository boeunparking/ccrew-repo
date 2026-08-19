output "source_bucket_arn" {
  value = aws_s3_bucket.source.arn
}

output "destination_bucket_arn" {
  value = aws_s3_bucket.destination.arn
}
