# This module creates Kinesis Firehose service (optionally), SQS, lambda function OXBOW
# to receive data and convert it into parquet then Delta log is added by Oxbow lambda

locals {
}

resource "aws_lambda_function" "auto_tagging" {
  count = var.enable_auto_tagging == true ? 1 : 0

  description   = var.lambda_description
  s3_key        = var.auto_tagging_s3_key
  s3_bucket     = var.auto_tagging_s3_bucket
  function_name = "${var.lambda_function_name}-auto_tagging"
  role          = aws_iam_role.this_iam_role_lambda_kinesis.arn
  handler       = "provided"
  runtime       = "provided.al2"
  memory_size   = var.lambda_memory_size
  # lets set 2 minutes
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  environment {
    variables = {
      AWS_S3_LOCKING_PROVIDER = var.aws_s3_locking_provider
      RUST_LOG                = "deltalake=${var.rust_log_deltalake_debug_level},oxbow=${var.rust_log_oxbow_debug_level}"
      DYNAMO_LOCK_TABLE_NAME  = var.dynamodb_table_name
    }
  }
  tags = var.tags
}


resource "aws_sqs_queue" "auto_tagging" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name   = "${var.sqs_fifo_queue_name}-auto_tagging"
  policy = data.aws_iam_policy_document.this_sqs_queue_policy_data.json

  content_based_deduplication = true
  fifo_queue                  = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.this_sqs_fifo_dlq[0].arn
    maxReceiveCount     = 8
  })
}

resource "aws_lambda_event_source_mapping" "auto_tagging" {
  count = var.enable_auto_tagging == true ? 1 : 0

  event_source_arn = aws_sqs_queue.auto_tagging[0].arn
  function_name    = aws_lambda_function.auto_tagging[0].arn
}


resource "aws_lambda_permission" "auto_tagging" {
  count = var.enable_auto_tagging == true ? 1 : 0

  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_tagging[0].arn
  principal     = "s3.amazonaws.com"
  source_arn    = var.warehouse_bucket_arn
}
