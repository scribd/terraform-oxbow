# This is the optional Autotagging feature.

resource "aws_lambda_function" "auto_tagging" {
  count         = var.enable_auto_tagging == true ? 1 : 0
  architectures = var.architectures
  description   = var.lambda_description
  s3_key        = var.auto_tagging_s3_key
  s3_bucket     = var.auto_tagging_s3_bucket
  function_name = "${var.lambda_function_name}-auto_tagging"
  role          = aws_iam_role.auto_tagging_lambda[0].arn
  handler       = "provided"
  runtime       = "provided.al2023"
  memory_size   = var.lambda_memory_size
  # lets set 2 minutes
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  environment {
    variables = {
      UNWRAP_SNS_ENVELOPE = var.sns_topic_arn == "" ? false : true
    }
  }

  tags = var.tags
}

resource "aws_sqs_queue" "auto_tagging_dl" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name   = "${var.sqs_queue_name}-auto_tagging-dl"
  policy = data.aws_iam_policy_document.auto_tagging_sqs_dl[0].json

  tags = var.tags
}

resource "aws_sqs_queue" "auto_tagging" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name                       = "${var.sqs_queue_name}-auto_tagging"
  policy                     = var.sns_topic_arn == "" ? data.aws_iam_policy_document.auto_tagging_sqs[0].json : data.aws_iam_policy_document.auto_tagging_sns[0].json
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.auto_tagging_dl[0].arn
    maxReceiveCount     = var.sqs_redrive_policy_maxReceiveCount
  })

  tags = var.tags
}

resource "aws_sns_topic_subscription" "auto_tagging" {
  count = var.enable_auto_tagging == true ? var.sns_topic_arn == "" ? 0 : 1 : 0

  topic_arn = var.sns_topic_arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.auto_tagging[0].arn
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
  count = var.enable_auto_tagging == true ? 1 : 0

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

data "aws_iam_policy_document" "auto_tagging_sns" {
  count = var.enable_auto_tagging == true ? var.sns_topic_arn == "" ? 0 : 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage"]
    resources = ["arn:aws:sqs:*:*:${var.sqs_queue_name}-auto_tagging", ]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.sns_topic_arn]
    }
  }

}

data "aws_iam_policy_document" "auto_tagging_sqs_dl" {
  count = var.enable_auto_tagging == true ? 1 : 0

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

### IAM role
data "aws_iam_policy_document" "auto_tagging_assume_role" {
  count = var.enable_auto_tagging == true ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
    ]
  }
}


resource "aws_iam_role" "auto_tagging_lambda" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name                = "${var.oxbow_lambda_role_name}-auto_tagging"
  assume_role_policy  = data.aws_iam_policy_document.auto_tagging_assume_role[0].json
  managed_policy_arns = [aws_iam_policy.auto_tagging_lambda[0].arn]

  tags = var.tags
}

resource "aws_iam_policy" "auto_tagging_lambda" {
  count = var.enable_auto_tagging == true ? 1 : 0

  name   = "${var.lambda_permissions_policy_name}-auto_tagging"
  policy = data.aws_iam_policy_document.auto_tagging_lambda[0].json
}


data "aws_iam_policy_document" "auto_tagging_lambda" {
  count = var.enable_auto_tagging == true ? 1 : 0

  statement {
    sid = "dynamodb"
    actions = [
      "dynamodb:*",
    ]
    resources = [aws_dynamodb_table.this_oxbow_locking.arn, "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.logstore_dynamodb_table_name}"]
  }
  statement {
    sid = "s3"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:PutObjectTagging",
      "s3:DeleteObjectTagging",
    ]
    resources = [
      "${var.warehouse_bucket_arn}/${var.s3_path}",
      "${var.warehouse_bucket_arn}/${var.s3_path}/*"
    ]
  }
  statement {
    sid = "s3read"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = [
      var.warehouse_bucket_arn,
      "${var.warehouse_bucket_arn}/*"
    ]
  }
  statement {
    sid     = "sqs"
    actions = ["sqs:*"]
    resources = [
      aws_sqs_queue.auto_tagging[0].arn,
      aws_sqs_queue.auto_tagging_dl[0].arn,
    ]
  }

  statement {
    sid = "logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}
