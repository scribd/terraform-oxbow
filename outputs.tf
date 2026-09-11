output "lambda_arn" {
  description = "Oxbow lambda ARN"
  value       = module.oxbow_lambda.lambda_function_arn
}

output "lambda_role_arn" {
  description = "IAM role ARN shared by the oxbow and group-events lambdas"
  value       = module.oxbow_lambda.lambda_role_arn
}

output "sqs_queue_arn" {
  description = "ARN of the queue oxbow consumes from"
  value       = local.oxbow_source_queue_arn
}

output "ingest_queue_arn" {
  description = "ARN of the queue S3 or SNS delivers object-created events to"
  value       = local.ingest_queue_arn
}

output "dead_letter_queue_arns" {
  description = "ARNs of every dead letter queue this module creates"
  value = compact([
    local.enabled.group_events ? module.oxbow_fifo_queue[0].dead_letter_queue_arn : module.oxbow_queue[0].dead_letter_queue_arn,
    local.enabled.group_events ? module.group_events_queue[0].dead_letter_queue_arn : "",
    local.enabled.auto_tagging ? module.auto_tagging_queue[0].dead_letter_queue_arn : "",
    local.enabled.glue_create ? module.glue_create_queue[0].dead_letter_queue_arn : "",
    local.enabled.glue_sync ? module.glue_sync_queue[0].dead_letter_queue_arn : "",
  ])
}

output "autotag_sqs_arn" {
  description = "SQS ARN for the auto-tagging lambda"
  value       = local.enabled.auto_tagging ? module.auto_tagging_queue[0].queue_arn : ""
}

output "autotag_lambda" {
  description = "Auto-tagging lambda ARN"
  value       = local.enabled.auto_tagging ? module.auto_tagging_lambda[0].lambda_function_arn : ""
}

output "dynamodb_lock_table_arn" {
  description = "ARN of the delta-rs S3 locking table"
  value       = aws_dynamodb_table.oxbow_locking.arn
}

output "enabled_stages" {
  description = "Which optional stages are switched on"
  value       = local.enabled
}

output "dead_letters_monitor_ids" {
  description = "IDs of the Datadog dead letter monitors"
  value       = [for monitor in datadog_monitor.dead_letters : monitor.id]
}
