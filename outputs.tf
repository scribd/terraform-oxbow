output "kinesis_stream_arn" {
  description = "Kinesis stream arn"
  value       = local.enable_kinesis_firehose_delivery_stream ? aws_kinesis_firehose_delivery_stream.this_kinesis[0].arn : ""
}

output "lambda_arn" {
  description = "Lambda arn"
  value       = aws_lambda_function.this_lambda.arn
}

output "sqs_queue_arn" {
  description = "SQSqueue ARN"
  value       = length(aws_sqs_queue.this_sqs) > 0 ? aws_sqs_queue.this_sqs[0].arn : aws_sqs_queue.this_sqs_fifo[0].arn
}
