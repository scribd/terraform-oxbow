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

  tags = var.tags
}

resource "aws_sqs_queue" "auto_tagging_dl" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name   = "${var.sqs_queue_name}-auto_tagging-dl"
  policy = data.aws_iam_policy_document.auto_tagging_sqs_dl.json

  tags = var.tags
}

resource "aws_sqs_queue" "auto_tagging" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name                       = "${var.sqs_queue_name}-auto_tagging"
  policy                     = data.aws_iam_policy_document.auto_tagging_sqs.json
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.auto_tagging_dl[0].arn
    maxReceiveCount     = var.sqs_redrive_policy_maxReceiveCount
  })

  tags = var.tags
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

### policies
data "aws_iam_policy_document" "auto_tagging_sqs" {
  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["sqs:SendMessage"]
    # Hard-coding an ARN like syntax here because of the dependency cycle
    resources = [
      "arn:aws:sqs:*:*:${var.sqs_queue_name}-auto_tagging",
    ]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.warehouse_bucket_arn]
    }
  }
}

data "aws_iam_policy_document" "auto_tagging_sqs_dl" {
  statement {
    sid    = "DLQSendMessages"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "sqs:SendMessage"
    ]
    resources = [
      "${var.sqs_queue_name}-auto_tagging-dl",
    ]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:sqs:*:*:${var.sqs_queue_name}-auto_tagging"
      ]
    }
  }
}
