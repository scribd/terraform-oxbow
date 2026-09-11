data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  # One gate per optional stage. Each stage's config variable is null when the
  # stage is off, so every count and conditional in the module keys off this.
  enabled = {
    bucket_notification = var.bucket_notification != null
    group_events        = var.group_events != null
    auto_tagging        = var.auto_tagging != null
    glue_catalog_table  = var.glue_catalog_table != null
    glue_create         = var.glue_create != null
    glue_sync           = var.glue_sync != null
    dl_monitoring       = var.dead_letter_monitoring != null
    sns_delivery        = var.sns_delivery != null
  }

  sns_topic_arn = try(var.sns_delivery.topic_arn, null)

  # S3 bucket ARNs carry no account id, so a cross-account warehouse bucket has
  # to name its owner explicitly or the SourceAccount conditions reject it.
  warehouse_bucket_account_id = coalesce(var.warehouse_bucket_account_id, local.account_id)

  # Oxbow reads from the FIFO queue the group-events lambda feeds, or straight
  # from the standard queue when grouping is off. The queue S3 (or SNS)
  # delivers object-created events to is the group-events queue under grouping
  # and the same standard queue otherwise.
  fifo_queue_name = local.enabled.group_events ? "${trimsuffix(var.group_events.fifo_queue_name, ".fifo")}.fifo" : ""
  fifo_dlq_name   = local.enabled.group_events ? "${trimsuffix(var.group_events.fifo_dl_queue_name, ".fifo")}.fifo" : ""

  oxbow_source_queue_name = local.enabled.group_events ? local.fifo_queue_name : var.sqs_queue_name
  ingest_queue_name       = local.enabled.group_events ? var.group_events.queue_name : var.sqs_queue_name

  oxbow_source_queue_arn = local.enabled.group_events ? module.oxbow_fifo_queue[0].queue_arn : module.oxbow_queue[0].queue_arn
  ingest_queue_arn       = local.enabled.group_events ? module.group_events_queue[0].queue_arn : module.oxbow_queue[0].queue_arn

  auto_tagging_queue_name = "${var.sqs_queue_name}-auto_tagging"
  auto_tagging_function   = "${var.lambda_function_name}-auto_tagging"
  auto_tagging_role_name  = "${var.oxbow_lambda_role_name}-auto_tagging"
  auto_tagging_policy     = "${var.lambda_permissions_policy_name}-auto_tagging"

  warehouse_prefix_arn = "${var.warehouse_bucket_arn}/${var.s3_path}"

  logstore_table_arn = "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.logstore_dynamodb_table_name}"

  # The set delta-rs documents for the DynamoDB locking provider, plus the
  # DescribeTable its client issues on init. Deliberately no CreateTable: this
  # module creates the lock table and the logstore table is an existing input.
  # https://delta-io.github.io/delta-rs/usage/writing/writing-to-s3-with-locking-provider/
  expected_dynamodb_actions = [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:Query",
    "dynamodb:DescribeTable",
  ]

  delta_lock_table_arns = [aws_dynamodb_table.oxbow_locking.arn, local.logstore_table_arn]

  glue_catalog_resources = [
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/*",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/*",
  ]

  # The five actions a lambda's event source mapping poller needs on its queue.
  sqs_consumer_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes",
    "sqs:GetQueueUrl",
    "sqs:ChangeMessageVisibility",
  ]

  log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group"

  # Queues with no cross-service publisher need no resource policy at all, but
  # the previous version of this module left a world-writable one on them
  # (Allow sqs:SendMessage to Principal "*" under a ForAllValues condition on
  # aws:SourceArn, which AWS evaluates as true whenever the key is absent --
  # i.e. on every direct SendMessage call). Dropping the policy from config
  # would leave that grant in place, since aws_sqs_queue.policy is computed, so
  # overwrite it with a deny instead. Redrive is gated by the redrive allow
  # policy, not by this.
  same_account_only_statements = {
    deny_outside_account = {
      sid        = "DenyOutsideAccount"
      effect     = "Deny"
      actions    = ["sqs:*"]
      principals = [{ type = "AWS", identifiers = ["*"] }]
      condition = [
        {
          test     = "StringNotEquals"
          variable = "aws:PrincipalAccount"
          values   = [local.account_id]
        },
        # aws:PrincipalAccount is absent for a service principal, and
        # StringNotEquals is true on an absent key, so without this the deny
        # would also catch AWS acting on our behalf -- an operator draining a
        # DLQ through SQS redrive, for one.
        {
          test     = "Bool"
          variable = "aws:PrincipalIsAWSService"
          values   = ["false"]
        },
      ]
    }
  }

  # Oxbow and the group-events lambda share one role, so that role needs the
  # group-events log group too; every other lambda's logs policy comes from the
  # lambda module and is already scoped to its own group.
  group_events_log_group_arns = local.enabled.group_events ? [
    "${local.log_group_arn}:/aws/lambda/${var.group_events.lambda_function_name}:*",
    "${local.log_group_arn}:/aws/lambda/${var.group_events.lambda_function_name}:*:*",
  ] : []
}

# Provider limits are enforced at apply, not at plan: an over-length Lambda or
# IAM name fails mid-apply after earlier resources have already changed.
locals {
  name_limits = merge(
    {
      "lambda_function_name (Lambda, 64)"        = [var.lambda_function_name, 64]
      "oxbow_lambda_role_name (IAM role, 64)"    = [var.oxbow_lambda_role_name, 64]
      "lambda_permissions_policy_name (IAM, 64)" = [var.lambda_permissions_policy_name, 64]
      "sqs_queue_name (SQS, 80)"                 = [var.sqs_queue_name, 80]
      "sqs_queue_name_dl (SQS, 80)"              = [var.sqs_queue_name_dl, 80]
      "dynamodb_table_name (DynamoDB, 255)"      = [var.dynamodb_table_name, 255]
    },
    local.enabled.group_events ? {
      "group_events.lambda_function_name (Lambda, 64)" = [var.group_events.lambda_function_name, 64]
      "group_events.queue_name (SQS, 80)"              = [var.group_events.queue_name, 80]
      "group_events.dl_queue_name (SQS, 80)"           = [var.group_events.dl_queue_name, 80]
      "group_events FIFO queue name (SQS, 80)"         = [local.fifo_queue_name, 80]
      "group_events FIFO DLQ name (SQS, 80)"           = [local.fifo_dlq_name, 80]
    } : {},
    local.enabled.auto_tagging ? {
      "auto-tagging function name (Lambda, 64)" = [local.auto_tagging_function, 64]
      "auto-tagging role name (IAM role, 64)"   = [local.auto_tagging_role_name, 64]
      "auto-tagging policy name (IAM, 64)"      = [local.auto_tagging_policy, 64]
      "auto-tagging queue name (SQS, 80)"       = [local.auto_tagging_queue_name, 80]
      "auto-tagging DLQ name (SQS, 80)"         = ["${local.auto_tagging_queue_name}-dl", 80]
    } : {},
    local.enabled.glue_create ? {
      "glue_create.lambda_function_name (Lambda, 64)" = [var.glue_create.lambda_function_name, 64]
      "glue_create.iam_role_name (IAM role, 64)"      = [var.glue_create.iam_role_name, 64]
      "glue_create.iam_policy_name (IAM, 64)"         = [var.glue_create.iam_policy_name, 64]
      "glue_create.sqs_queue_name (SQS, 80)"          = [var.glue_create.sqs_queue_name, 80]
      "glue_create.sqs_queue_name_dl (SQS, 80)"       = [var.glue_create.sqs_queue_name_dl, 80]
      "glue_create.athena_bucket_name (S3, 63)"       = [var.glue_create.athena_bucket_name, 63]
    } : {},
    local.enabled.glue_sync ? {
      "glue_sync.lambda_function_name (Lambda, 64)" = [var.glue_sync.lambda_function_name, 64]
      "glue_sync.iam_role_name (IAM role, 64)"      = [var.glue_sync.iam_role_name, 64]
      "glue_sync.iam_policy_name (IAM, 64)"         = [var.glue_sync.iam_policy_name, 64]
      "glue_sync.sqs_queue_name (SQS, 80)"          = [var.glue_sync.sqs_queue_name, 80]
      "glue_sync.sqs_queue_name_dl (SQS, 80)"       = [var.glue_sync.sqs_queue_name_dl, 80]
    } : {},
  )

  over_limit_names = [
    for label, spec in local.name_limits :
    "${label}: ${length(spec[0])} chars, limit ${spec[1]} -- ${spec[0]}"
    if length(spec[0]) > tonumber(spec[1])
  ]
}

resource "terraform_data" "name_length_guard" {
  lifecycle {
    precondition {
      condition     = length(local.over_limit_names) == 0
      error_message = "Generated names exceed their AWS limit:\n${join("\n", local.over_limit_names)}"
    }
  }
}
