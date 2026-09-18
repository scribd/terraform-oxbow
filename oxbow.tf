# Oxbow converts parquet objects landing in the bucket into Delta
# tables. S3 (directly, or fanned out through SNS) notifies a queue; the queue
# drives the lambda.

locals {
  oxbow_environment = !local.enabled.oxbow ? {} : merge(
    {
      RUST_LOG               = "deltalake=${var.rust_log_deltalake_debug_level},oxbow=${var.rust_log_oxbow_debug_level}"
      DYNAMO_LOCK_TABLE_NAME = var.dynamodb_table_name
    },
    # With grouping on, the group-events lambda already unwrapped the envelope.
    !local.enabled.group_events && local.enabled.sns_delivery ? { UNWRAP_SNS_ENVELOPE = "true" } : {},
    var.enable_schema_evolution ? { SCHEMA_EVOLUTION = "true" } : {},
  )
}

module "oxbow_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "8.8.0"

  count = local.enabled.oxbow ? 1 : 0

  function_name = var.oxbow.lambda_function_name
  description   = var.lambda_description
  handler       = "provided"
  runtime       = "provided.al2023"
  architectures = var.architectures

  create_package = false
  s3_existing_package = {
    bucket = var.oxbow.lambda_s3_bucket
    key    = var.oxbow.lambda_s3_key
  }

  memory_size                    = var.lambda_memory_size
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions
  environment_variables          = local.oxbow_environment

  role_name     = var.oxbow.role_name
  attach_policy = true
  policy        = aws_iam_policy.oxbow_lambda[0].arn

  use_existing_cloudwatch_log_group = !local.manage_log_group.oxbow
  cloudwatch_logs_retention_in_days = var.cloudwatch_logs_retention_in_days

  attach_create_log_group_permission = false

  attach_policy_statements = local.enabled.group_events
  policy_statements = local.enabled.group_events ? {
    group_events_logs = {
      effect    = "Allow"
      actions   = local.lambda_logs_actions
      resources = local.group_events_log_group_arns
    }
  } : {}

  # The lambda module gates this on create_unqualified_alias_allowed_triggers,
  # despite the name. Setting that false deletes every stage's SQS mapping and
  # stops the pipeline; it is left at its default everywhere for that reason.
  event_source_mapping = {
    sqs = {
      event_source_arn = local.oxbow_source_queue_arn
    }
  }

  tags = var.tags
}

module "oxbow_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  count = local.oxbow_standard_queue ? 1 : 0

  name                       = local.ingest_queue_name
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  sqs_managed_sse_enabled    = var.sqs_managed_sse_enabled

  create_queue_policy     = true
  queue_policy_statements = local.ingest_queue_policy_statements

  create_dlq                     = true
  dlq_name                       = var.oxbow.dl_queue_name
  dlq_message_retention_seconds  = var.message_retention_seconds
  dlq_delay_seconds              = 0
  dlq_visibility_timeout_seconds = 30
  redrive_policy                 = { maxReceiveCount = var.sqs_redrive_policy_maxReceiveCount }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}

resource "aws_iam_policy" "oxbow_lambda" {
  count = local.enabled.oxbow ? 1 : 0

  # aws_iam_policy.description is ForceNew and the destroy does not detach
  # first, so changing it replaces the policy and then fails on DeleteConflict.
  # These four strings must stay byte-identical to v1.0.9; see UPGRADING.
  name   = var.oxbow.policy_name
  policy = data.aws_iam_policy_document.oxbow_lambda[0].json
  tags   = var.tags
}

data "aws_iam_policy_document" "oxbow_lambda" {
  count = local.enabled.oxbow ? 1 : 0

  statement {
    sid       = "TableCreationLock"
    effect    = "Allow"
    actions   = local.expected_dynamodb_actions
    resources = [local.lock_table_arn]
  }

  statement {
    sid    = "PrefixObjectReadWrite"
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
    resources = ["${local.s3_prefix_arn}/*"]
  }

  statement {
    sid       = "BucketList"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketVersions"]
    resources = [var.bucket_arn]
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
      actions   = ["sqs:SendMessage"]
      resources = [module.oxbow_fifo_queue[0].queue_arn]
    }
  }
}

locals {
  oxbow_lambda_queue_arns = local.enabled.group_events ? [
    module.group_events_queue[0].queue_arn,
    module.oxbow_fifo_queue[0].queue_arn,
  ] : (local.oxbow_standard_queue ? [module.oxbow_queue[0].queue_arn] : [])
}
