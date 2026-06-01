

output "lambda_arn" {
  description = "Lambda arn"
  value       = aws_lambda_function.this_lambda.arn
}

output "sqs_queue_arn" {
  description = "SQSqueue ARN"
  value       = length(aws_sqs_queue.this_sqs) > 0 ? aws_sqs_queue.this_sqs[0].arn : aws_sqs_queue.oxbow_lambda_fifo_sqs[0].arn
}

output "autotag_sqs_arn" {
  description = "SQS arn for the autotagging lambda"
  value       = var.enable_auto_tagging == false ? "" : aws_sqs_queue.auto_tagging[0].arn
}

output "autotag_lambda" {
  description = "Autotagging lambda Arn"
  value       = var.enable_auto_tagging == false ? "" : aws_lambda_function.auto_tagging[0].arn
}

output "dead_letters_monitor_ids" {
  description = "IDs of the Datadog dead letter monitors"
  value       = [for monitor in datadog_monitor.dead_letters_monitor : monitor.id]
}
