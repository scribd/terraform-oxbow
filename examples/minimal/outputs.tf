output "ingest_queue_arn" {
  description = "Queue the bucket notification delivers to"
  value       = module.oxbow.ingest_queue_arn
}

output "lambda_arn" {
  description = "Oxbow lambda"
  value       = module.oxbow.lambda_arn
}
