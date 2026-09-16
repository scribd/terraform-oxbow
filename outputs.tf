output "lambda_arn" {
  description = "Oxbow lambda ARN"
  value       = local.enabled.oxbow ? module.oxbow_lambda[0].lambda_function_arn : ""
}

output "lambda_role_arn" {
  description = "IAM role ARN shared by the oxbow and group-events lambdas"
  value       = local.enabled.oxbow ? module.oxbow_lambda[0].lambda_role_arn : ""
}

output "sqs_queue_arn" {
  description = "ARN of the queue oxbow consumes from; empty when the oxbow stage is off"
  value       = local.oxbow_source_queue_arn == null ? "" : local.oxbow_source_queue_arn
}

output "ingest_queue_arn" {
  description = "ARN of the queue S3 or SNS delivers object-created events to; empty when the oxbow stage is off"
  value       = local.ingest_queue_arn == null ? "" : local.ingest_queue_arn
}

output "dead_letter_queue_arns" {
  description = "ARNs of every dead letter queue this module creates"
  value = compact([
    local.enabled.group_events ? module.oxbow_fifo_queue[0].dead_letter_queue_arn : (local.oxbow_standard_queue ? module.oxbow_queue[0].dead_letter_queue_arn : ""),
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
  description = "ARN of the delta-rs S3 locking table this module was pointed at; empty when no stage uses one"
  value       = var.dynamodb_table_name == null ? "" : local.lock_table_arn
}

output "enabled_stages" {
  description = "Which optional stages are switched on"
  value       = local.enabled
}

output "dead_letters_monitor_ids" {
  description = "IDs of the Datadog dead letter monitors"
  value       = [for monitor in datadog_monitor.dead_letters : monitor.id]
}
