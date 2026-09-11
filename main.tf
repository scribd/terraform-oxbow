# Oxbow converts parquet objects landing in the warehouse bucket into Delta
# tables. S3 (directly, or fanned out through SNS) notifies a queue; the queue
# drives the lambda.

locals {
  oxbow_environment = merge(
    {
      AWS_S3_LOCKING_PROVIDER = var.aws_s3_locking_provider
      RUST_LOG                = "deltalake=${var.rust_log_deltalake_debug_level},oxbow=${var.rust_log_oxbow_debug_level}"
      DYNAMO_LOCK_TABLE_NAME  = var.dynamodb_table_name
      DELTA_DYNAMO_TABLE_NAME = var.logstore_dynamodb_table_name
    },
    # With grouping on, the group-events lambda already unwrapped the envelope.
    !local.enabled.group_events && local.enabled.sns_delivery ? { UNWRAP_SNS_ENVELOPE = true } : {},
    var.enable_schema_evolution ? { SCHEMA_EVOLUTION = true } : {},
  )
}

module "oxbow_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "8.8.0"

  function_name = var.lambda_function_name
  description   = var.lambda_description
  handler       = "provided"
  runtime       = "provided.al2023"
  architectures = var.architectures

  create_package = false
  s3_existing_package = {
    bucket = var.lambda_s3_bucket
    key    = var.lambda_s3_key
  }

  memory_size                    = var.lambda_memory_size
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions
  environment_variables          = local.oxbow_environment

  role_name     = var.oxbow_lambda_role_name
  attach_policy = true
  policy        = aws_iam_policy.oxbow_lambda.arn

  use_existing_cloudwatch_log_group = !var.manage_lambda_log_groups
  cloudwatch_logs_retention_in_days = var.cloudwatch_logs_retention_in_days
  attach_policy_statements          = local.enabled.group_events
  policy_statements = local.enabled.group_events ? {
    group_events_logs = {
      effect    = "Allow"
      actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      resources = local.group_events_log_group_arns
    }
  } : {}

  event_source_mapping = {
    sqs = {
      event_source_arn = local.oxbow_source_queue_arn
    }
  }
  create_current_version_allowed_triggers = false

  tags = var.tags
}

module "oxbow_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  count = local.enabled.group_events ? 0 : 1

  name                       = local.ingest_queue_name
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  sqs_managed_sse_enabled    = var.sqs_managed_sse_enabled

  create_queue_policy     = true
  queue_policy_statements = local.ingest_queue_policy_statements

  create_dlq                     = true
  dlq_name                       = var.sqs_queue_name_dl
  dlq_delay_seconds              = 0
  dlq_visibility_timeout_seconds = 30
  redrive_policy                 = { maxReceiveCount = var.sqs_redrive_policy_maxReceiveCount }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}

# Publishers of the object-created events. Both paths can be live at once --
# the bucket notifying the queue directly while the queue is also subscribed to
# a topic -- so these are additive, not either/or.
locals {
  s3_publishes_to_ingest_queue = local.enabled.bucket_notification || !local.enabled.sns_delivery

  ingest_queue_policy_statements = merge(
    local.s3_publishes_to_ingest_queue ? {
      s3_send = {
        effect     = "Allow"
        actions    = ["sqs:SendMessage"]
        principals = [{ type = "Service", identifiers = ["s3.amazonaws.com"] }]
        condition = [
          {
            test     = "ArnEquals"
            variable = "aws:SourceArn"
            values   = [var.warehouse_bucket_arn]
          },
          {
            test     = "StringEquals"
            variable = "aws:SourceAccount"
            values   = [local.warehouse_bucket_account_id]
          },
        ]
      }
    } : {},
    local.enabled.sns_delivery ? {
      sns_send = {
        effect     = "Allow"
        actions    = ["sqs:SendMessage"]
        principals = [{ type = "Service", identifiers = ["sns.amazonaws.com"] }]
        condition = [{
          test     = "ArnEquals"
          variable = "aws:SourceArn"
          values   = [local.sns_topic_arn]
        }]
      }
    } : {},
  )
}

resource "aws_iam_policy" "oxbow_lambda" {
  name        = var.lambda_permissions_policy_name
  description = "Oxbow lambda access to the warehouse prefix, its queues and the Delta lock tables"
  policy      = data.aws_iam_policy_document.oxbow_lambda.json
  tags        = var.tags
}

data "aws_iam_policy_document" "oxbow_lambda" {
  statement {
    sid       = "DeltaLockTables"
    effect    = "Allow"
    actions   = local.expected_dynamodb_actions
    resources = local.delta_lock_table_arns
  }

  statement {
    sid    = "WarehousePrefixReadWrite"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:DeleteObject",
      "s3:DeleteObjectTagging",
    ]
    resources = ["${local.warehouse_prefix_arn}/*"]
  }

  statement {
    sid       = "WarehouseBucketList"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketVersions"]
    resources = [var.warehouse_bucket_arn]
  }

  statement {
    sid       = "ConsumeQueues"
    effect    = "Allow"
    actions   = local.sqs_consumer_actions
    resources = local.oxbow_lambda_queue_arns
  }

  # The group-events lambda shares this role and writes into the FIFO queue.
  dynamic "statement" {
    for_each = local.enabled.group_events ? [1] : []
    content {
      sid       = "ProduceToFifoQueue"
      effect    = "Allow"
      actions   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      resources = [module.oxbow_fifo_queue[0].queue_arn]
    }
  }
}

locals {
  oxbow_lambda_queue_arns = local.enabled.group_events ? [
    module.group_events_queue[0].queue_arn,
    module.oxbow_fifo_queue[0].queue_arn,
  ] : [module.oxbow_queue[0].queue_arn]
}

# Safe concurrent writes to Delta tables.
resource "aws_dynamodb_table" "oxbow_locking" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  # Partition key name is hard-coded in delta-rs.
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
