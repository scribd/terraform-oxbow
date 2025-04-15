# This module creates SQS, lambda function OXBOW
# to receive data and convert it into parquet then Delta log is added by Oxbow lambda
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  enable_aws_glue_catalog_table = var.enable_aws_glue_catalog_table
  enable_bucket_notification    = var.enable_bucket_notification
  enable_group_events           = var.enable_group_events
}


resource "aws_glue_catalog_table" "this_glue_table" {
  count = local.enable_aws_glue_catalog_table ? 1 : 0

  name          = var.glue_table_name
  description   = var.glue_table_description
  database_name = var.glue_database_name
  parameters = {
    "classification" = "parquet"
  }
  storage_descriptor {
    location      = var.glue_location_uri
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    ser_de_info {
      parameters = {
        "serialization.format" = "1"
      }
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
    dynamic "columns" {
      for_each = var.parquet_schema
      content {
        name       = columns.value.name
        parameters = columns.value.parameters
        type       = columns.value.type
      }
    }
  }
}

locals {
  oxbow_lambda_unwrap_sns_event      = var.enable_group_events == true ? {} : var.sns_topic_arn == "" ? {} : { UNWRAP_SNS_ENVELOPE = true }
  group_eventlambda_unwrap_sns_event = var.sns_topic_arn == "" ? {} : { UNWRAP_SNS_ENVELOPE = true }
  oxbow_lambda_schema_evolution      = var.enable_schema_evolution == false ? {} : { SCHEMA_EVOLUTION = true }

}

resource "aws_lambda_function" "this_lambda" {
  description   = var.lambda_description
  architectures = var.architectures
  s3_key        = var.lambda_s3_key
  s3_bucket     = var.lambda_s3_bucket
  function_name = var.lambda_function_name
  role          = aws_iam_role.oxbow_lambda_role.arn
  handler       = "provided"
  runtime       = "provided.al2023"
  memory_size   = var.lambda_memory_size
  # lets set 2 minutes
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  environment {
    variables = merge({
      AWS_S3_LOCKING_PROVIDER = var.aws_s3_locking_provider
      RUST_LOG                = "deltalake=${var.rust_log_deltalake_debug_level},oxbow=${var.rust_log_oxbow_debug_level}"
      DYNAMO_LOCK_TABLE_NAME  = var.dynamodb_table_name
      DELTA_DYNAMO_TABLE_NAME = var.logstore_dynamodb_table_name
      },
      local.oxbow_lambda_unwrap_sns_event, local.oxbow_lambda_schema_evolution
    )
  }
  tags = var.tags
}
#### This lambda is optional and used only when grouping of events is required
resource "aws_lambda_function" "group_events_lambda" {
  count         = local.enable_group_events ? 1 : 0
  architectures = var.architectures
  description   = "Group events for oxbow based on the table prefix"
  s3_key        = var.events_lambda_s3_key
  s3_bucket     = var.events_lambda_s3_bucket
  function_name = var.events_lambda_function_name
  role          = aws_iam_role.oxbow_lambda_role.arn
  handler       = "provided"
  runtime       = "provided.al2023"

  environment {
    variables = merge({
      RUST_LOG  = var.rust_log_oxbow_debug_level
      QUEUE_URL = aws_sqs_queue.oxbow_lambda_fifo_sqs[0].url
    }, local.group_eventlambda_unwrap_sns_event)
  }
}


data "aws_iam_policy_document" "oxbow_lambda_fifo_sqs" {
  count = local.enable_group_events ? 1 : 0
  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    # Hard-coding an ARN like syntax here because of the dependency cycle
    resources = ["arn:aws:sqs:*:*:${var.sqs_fifo_queue_name}.fifo"]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.warehouse_bucket_arn]
    }
  }
}

data "aws_iam_policy_document" "oxbow_lambda_fifo_sqs_dlq" {
  count = local.enable_group_events ? 1 : 0
  statement {
    sid    = "DLQSendMessages"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    resources = ["arn:aws:sqs:*:*:${var.sqs_fifo_DL_queue_name}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:sqs:*:*:${var.sqs_fifo_DL_queue_name}.fifo"
      ]
    }
  }
}

resource "aws_sqs_queue" "oxbow_lambda_fifo_sqs" {
  count                       = local.enable_group_events ? 1 : 0
  name                        = "${var.sqs_fifo_queue_name}.fifo"
  policy                      = data.aws_iam_policy_document.oxbow_lambda_fifo_sqs[0].json
  visibility_timeout_seconds  = var.sqs_visibility_timeout_seconds
  delay_seconds               = var.sqs_delay_seconds
  content_based_deduplication = true
  fifo_queue                  = true
  tags                        = var.tags
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.oxbow_lambda_fifo_sqs_dlq[0].arn
    maxReceiveCount     = 8
  })
}

resource "aws_sqs_queue" "oxbow_lambda_fifo_sqs_dlq" {
  count      = local.enable_group_events ? 1 : 0
  name       = "${var.sqs_fifo_DL_queue_name}.fifo"
  policy     = data.aws_iam_policy_document.oxbow_lambda_fifo_sqs_dlq[0].json
  fifo_queue = true
  tags       = var.tags
}

resource "aws_lambda_event_source_mapping" "group_events_lambda_sqs_trigger" {
  count                              = local.enable_group_events ? 1 : 0
  event_source_arn                   = aws_sqs_queue.group_events_lambda_sqs[0].arn
  function_name                      = aws_lambda_function.group_events_lambda[0].arn
  batch_size                         = var.group_event_lambda_batch_size
  maximum_batching_window_in_seconds = var.group_event_lambda_maximum_batching_window_in_seconds
}


data "aws_iam_policy_document" "group_event_lambda_sqs" {
  count = local.enable_group_events ? 1 : 0
  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    # Hard-coding an ARN like syntax here because of the dependency cycle
    resources = ["arn:aws:sqs:*:*:${var.sqs_group_queue_name}"]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.warehouse_bucket_arn]
    }
  }
}

data "aws_iam_policy_document" "group_event_lambda_sqs_dlq" {
  count = local.enable_group_events ? 1 : 0
  statement {
    sid    = "DLQSendMessages"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    resources = ["arn:aws:sqs:*:*:${var.sqs_group_DL_queue_name}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:sqs:*:*:${var.sqs_group_queue_name}"
      ]
    }
  }
}

resource "aws_sqs_queue" "group_events_lambda_sqs" {
  count                      = local.enable_group_events ? 1 : 0
  name                       = var.sqs_group_queue_name
  policy                     = var.sns_topic_arn == "" ? data.aws_iam_policy_document.group_event_lambda_sqs[0].json : data.aws_iam_policy_document.this_sns_to_sqs[0].json
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.group_events_lambda_sqs_dlq[0].arn
    maxReceiveCount     = 8
  })
  tags = var.tags
}

resource "aws_sqs_queue" "group_events_lambda_sqs_dlq" {
  count  = local.enable_group_events ? 1 : 0
  policy = data.aws_iam_policy_document.group_event_lambda_sqs_dlq[0].json
  name   = var.sqs_group_DL_queue_name
  tags   = var.tags
}



### This is to ensure we are triggering oxbow lambda properly whether group event is enable or not
### if group event is enabled we are using the fifo queue populated by group events as a source for oxbow
resource "aws_lambda_event_source_mapping" "this_lambda_events" {
  event_source_arn = local.enable_group_events ? aws_sqs_queue.oxbow_lambda_fifo_sqs[0].arn : aws_sqs_queue.this_sqs[0].arn
  function_name    = aws_lambda_function.this_lambda.arn
}

resource "aws_sqs_queue" "this_sqs" {
  count                      = local.enable_group_events ? 0 : 1
  name                       = var.sqs_queue_name
  policy                     = var.sns_topic_arn == "" ? data.aws_iam_policy_document.this_sqs_queue_policy_data.json : data.aws_iam_policy_document.this_sns_to_sqs[0].json
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.this_DL[0].arn
    maxReceiveCount     = var.sqs_redrive_policy_maxReceiveCount
  })
  tags = var.tags
}

resource "aws_sqs_queue" "this_DL" {
  count  = local.enable_group_events ? 0 : 1
  name   = var.sqs_queue_name_dl
  policy = data.aws_iam_policy_document.this_dead_letter_queue_policy.json
  tags   = var.tags
}

resource "aws_sns_topic_subscription" "this_sns_sub" {
  count = var.sns_topic_arn == "" ? 0 : 1

  topic_arn = var.sns_topic_arn
  protocol  = "sqs"
  endpoint  = local.enable_group_events ? aws_sqs_queue.group_events_lambda_sqs[0].arn : aws_sqs_queue.this_sqs[0].arn
}

resource "aws_lambda_permission" "this_lambda_allow_bucket_permissions" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this_lambda.arn
  principal     = "s3.amazonaws.com"
  source_arn    = var.warehouse_bucket_arn
}

# This resource should be disabled because of the limits in Terrafrom to create aws_s3_bucket_notification resources
# until it will be fixed
resource "aws_s3_bucket_notification" "this_bucket_notification" {
  count  = local.enable_bucket_notification ? 1 : 0
  bucket = var.warehouse_bucket_name
  queue {
    queue_arn     = local.enable_group_events ? aws_sqs_queue.group_events_lambda_sqs[0].arn : aws_sqs_queue.this_sqs[0].arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".parquet"
    filter_prefix = "${var.s3_path}/"
  }
  depends_on = [aws_lambda_permission.this_lambda_allow_bucket_permissions]
}

data "aws_iam_policy_document" "this_services_assume_role" {
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

resource "aws_iam_policy" "this_lambda_permissions" {
  name = var.lambda_permissions_policy_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["dynamodb:*"]
        Resource = [aws_dynamodb_table.this_oxbow_locking.arn, "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.logstore_dynamodb_table_name}"]
        Effect   = "Allow"
      },
      {
        Action = [
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:GetObjectVersion",
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:ListBucketVersions",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:PutObjectTagging",
        "s3:DeleteObjectTagging", ]
        Resource = [
          "${var.warehouse_bucket_arn}/${var.s3_path}",
          "${var.warehouse_bucket_arn}/${var.s3_path}/*"
        ]
        Effect = "Allow"
      },
      {
        Action = [
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:GetObjectVersion",
          "s3:GetBucketLocation",
          "s3:ListBucket",
        "s3:ListBucketVersions", ]
        Resource = [
          var.warehouse_bucket_arn,
          "${var.warehouse_bucket_arn}/*"
        ]
        Effect = "Allow"
      },
      {
        Action   = ["sqs:*"]
        Resource = local.enable_group_events ? [aws_sqs_queue.group_events_lambda_sqs[0].arn, aws_sqs_queue.oxbow_lambda_fifo_sqs[0].arn] : [aws_sqs_queue.this_sqs[0].arn]
        Effect   = "Allow"
      },
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = ["*"]
        Effect   = "Allow"
      }
    ]
  })
}

data "aws_iam_policy_document" "this_sqs_queue_policy_data" {
  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["sqs:SendMessage"]
    # Hard-coding an ARN like syntax here because of the dependency cycle
    resources = ["arn:aws:sqs:*:*:${var.sqs_queue_name}"]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.warehouse_bucket_arn]
    }
  }
}


data "aws_iam_policy_document" "this_sns_to_sqs" {
  count = var.sns_topic_arn == "" ? 0 : 1

  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage"]
    resources = local.enable_group_events ? ["arn:aws:sqs:*:*:${var.sqs_group_queue_name}"] : ["arn:aws:sqs:*:*:${var.sqs_queue_name}"]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.sns_topic_arn]
    }
  }

}

data "aws_iam_policy_document" "this_dead_letter_queue_policy" {
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
    resources = ["arn:aws:sqs:*:*:${var.sqs_queue_name_dl}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:sqs:*:*:${var.sqs_queue_name}"
      ]
    }
  }
}

resource "aws_iam_role" "oxbow_lambda_role" {
  name                = var.oxbow_lambda_role_name
  assume_role_policy  = data.aws_iam_policy_document.this_services_assume_role.json
  managed_policy_arns = [aws_iam_policy.this_lambda_permissions.arn]

  tags = var.tags
}

# The DynamoDb table is used for providing safe concurrent writes to delta
# tables.
resource "aws_dynamodb_table" "this_oxbow_locking" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  # Default name of the partition key hard-coded in delta-rs
  hash_key = "key"

  ttl {
    attribute_name = "leaseDuration"
    enabled        = true
  }

  attribute {
    name = "key"
    type = "S"
  }
  tags = var.tags
}
