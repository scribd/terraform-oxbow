data "aws_iam_policy_document" "glue_sync_sqs" {
  count = local.enable_glue_sync ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    resources = ["arn:aws:sqs:*:*:${var.glue_sync_config.sqs_queue_name}"]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.glue_sync_config.sns_topic_arn]
    }
  }
}

data "aws_iam_policy_document" "glue_sync_sqs_dl" {
  count = local.enable_glue_sync ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    resources = ["arn:aws:sqs:*:*:${var.glue_sync_config.sqs_queue_name_dl}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:sqs:*:*:${var.glue_sync_config.sqs_queue_name}"]
    }
  }
}

resource "aws_sqs_queue" "glue_sync" {
  count = local.enable_glue_sync ? 1 : 0

  name                       = var.glue_sync_config.sqs_queue_name
  policy                     = data.aws_iam_policy_document.glue_sync_sqs[0].json
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.glue_sync_dl[0].arn
    maxReceiveCount     = var.sqs_redrive_policy_maxReceiveCount
  })
  tags = var.tags
}

resource "aws_sqs_queue" "glue_sync_dl" {
  count = local.enable_glue_sync ? 1 : 0

  name   = var.glue_sync_config.sqs_queue_name_dl
  policy = data.aws_iam_policy_document.glue_sync_sqs_dl[0].json
  tags   = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "glue_syncredrive_allow_policy" {
  count = local.enable_glue_sync ? 1 : 0

  queue_url = aws_sqs_queue.glue_sync_dl[0].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.glue_sync[0].arn]
  })
}

resource "aws_sns_topic_subscription" "glue_sync_sns_sub" {
  count = local.enable_glue_sync ? 1 : 0

  topic_arn = var.glue_sync_config.sns_topic_arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.glue_sync[0].arn
}

data "aws_iam_policy_document" "glue_sync_assume" {
  count = local.enable_glue_sync ? 1 : 0

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

data "aws_iam_policy_document" "glue_sync" {
  count = local.enable_glue_sync ? 1 : 0
  statement {
    sid    = "GlueAllowTables"
    effect = "Allow"
    actions = [
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable"
    ]
    resources = [
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/*",
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/*"
    ]
  }
  statement {
    sid    = "GlueCatalogAllowDatabases"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateDatabase"
    ]
    resources = [
      "*"
    ]
  }
  statement {
    sid    = "TableExtLocS3RO"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions"
    ]
    resources = [
      var.warehouse_bucket_arn,
      "${var.warehouse_bucket_arn}/${var.s3_path}/*"
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.glue_sync[0].arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_sync_managed" {
  count = local.enable_glue_sync ? 1 : 0

  name        = var.glue_sync_config.iam_policy_name
  description = "Glue create policy allows access to Athena and S3"
  policy      = data.aws_iam_policy_document.glue_sync[0].json
  tags        = var.tags
}

resource "aws_iam_role" "glue_sync" {
  count = local.enable_glue_sync ? 1 : 0

  name                = var.glue_sync_config.iam_role_name
  assume_role_policy  = data.aws_iam_policy_document.glue_sync_assume[0].json
  managed_policy_arns = [aws_iam_policy.glue_sync_managed[0].arn]
  tags                = var.tags
}

resource "aws_lambda_function" "glue_sync_lambda" {
  count = local.enable_glue_sync ? 1 : 0

  description   = "Greate tables in AWS Glue catalog based on the table prefix"
  s3_key        = var.glue_sync_config.lambda_s3_key
  s3_bucket     = var.glue_sync_config.lambda_s3_bucket
  function_name = var.glue_sync_config.lambda_function_name
  role          = aws_iam_role.glue_sync[0].arn
  handler       = "provided"
  runtime       = "provided.al2"
  memory_size   = 1024
  timeout       = 120
  environment {
    variables = {
      RUST_LOG            = var.rust_log_oxbow_debug_level
      GLUE_PATH_REGEX     = var.glue_sync_config.path_regex
      UNWRAP_SNS_ENVELOPE = true
    }
  }
}

resource "aws_lambda_event_source_mapping" "glue_sync" {
  count = local.enable_glue_sync ? 1 : 0

  event_source_arn = aws_sqs_queue.glue_sync[0].arn
  function_name    = aws_lambda_function.glue_sync_lambda[0].arn
}
