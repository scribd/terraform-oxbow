data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  enabled = {
    oxbow                  = var.oxbow != null
    group_events           = var.group_events != null
    auto_tagging           = var.auto_tagging != null
    glue_create            = var.glue_create != null
    glue_sync              = var.glue_sync != null
    dead_letter_monitoring = var.dead_letter_monitoring != null
    sns_delivery           = var.sns_delivery != null
  }

  sns_topic_arn = local.enabled.sns_delivery ? var.sns_delivery.topic_arn : null

  bucket_account_id = coalesce(var.bucket_account_id, local.account_id)

  fifo_queue_name = local.enabled.group_events ? "${trimsuffix(var.group_events.fifo_queue_name, ".fifo")}.fifo" : ""
  fifo_dlq_name   = local.enabled.group_events ? "${trimsuffix(var.group_events.fifo_dl_queue_name, ".fifo")}.fifo" : ""

  # Under grouping, oxbow reads the FIFO queue and deliveries land on group-events.
  oxbow_standard_queue = local.enabled.oxbow && !local.enabled.group_events

  oxbow_source_queue_name = local.enabled.group_events ? local.fifo_queue_name : (local.enabled.oxbow ? var.oxbow.queue_name : null)
  ingest_queue_name       = local.enabled.group_events ? var.group_events.queue_name : (local.enabled.oxbow ? var.oxbow.queue_name : null)

  oxbow_source_queue_arn = local.enabled.group_events ? module.oxbow_fifo_queue[0].queue_arn : (local.oxbow_standard_queue ? module.oxbow_queue[0].queue_arn : null)
  ingest_queue_arn       = local.enabled.group_events ? module.group_events_queue[0].queue_arn : (local.oxbow_standard_queue ? module.oxbow_queue[0].queue_arn : null)

  # Without oxbow there is nothing to derive from: see auto_tagging's validation.
  auto_tagging_suffix     = "-auto_tagging"
  auto_tagging_function   = local.enabled.auto_tagging ? coalesce(var.auto_tagging.function_name, local.enabled.oxbow ? "${var.oxbow.lambda_function_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_role_name  = local.enabled.auto_tagging ? coalesce(var.auto_tagging.role_name, local.enabled.oxbow ? "${var.oxbow.role_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_policy     = local.enabled.auto_tagging ? coalesce(var.auto_tagging.policy_name, local.enabled.oxbow ? "${var.oxbow.policy_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_queue_name = local.enabled.auto_tagging ? coalesce(var.auto_tagging.queue_name, local.enabled.oxbow ? "${var.oxbow.queue_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_dlq_name   = local.enabled.auto_tagging ? coalesce(var.auto_tagging.dl_queue_name, "${local.auto_tagging_queue_name}-dl") : null

  s3_prefix_arn = "${var.bucket_arn}/${var.s3_path}"

  dynamodb_table_arn_prefix = "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table"
  lock_table_arn            = var.dynamodb_table_name == null ? null : "${local.dynamodb_table_arn_prefix}/${var.dynamodb_table_name}"

  # The three calls the dynamodb_lock crate makes -- oxbow's own table-creation
  # lock, which is not delta-rs's logstore. See README's compatibility matrix.
  expected_dynamodb_actions = [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:DeleteItem",
  ]

  # Traced to the calls each binary makes: glue-sync is get_table + update_table
  # only, glue-create adds the create actions indirectly because Athena runs its
  # CREATE EXTERNAL TABLE DDL under the lambda's identity.
  # https://github.com/buoyant-data/oxbow/tree/main/lambdas
  glue_sync_actions   = ["glue:GetTable", "glue:UpdateTable"]
  glue_create_actions = ["glue:GetTable", "glue:CreateTable", "glue:GetDatabase", "glue:CreateDatabase"]

  # GetWorkGroup traces to no SDK call, and is kept only because
  # StartQueryExecution names a workgroup. Drop it if an apply proves it unused.
  athena_actions = ["athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetWorkGroup"]

  glue_catalog_resources = [
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/*",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/*",
  ]

  # Exactly AWSLambdaSQSQueueExecutionRole's SQS half. ChangeMessageVisibility is
  # for partial batch responses, which no event source mapping here enables.
  sqs_consumer_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes",
  ]

  # Both delivery paths can be live at once, so each queue composes the
  # publishers that actually write to it rather than choosing one.
  s3_send_statement = {
    sid        = "S3SendMessage"
    effect     = "Allow"
    actions    = ["sqs:SendMessage"]
    principals = [{ type = "Service", identifiers = ["s3.amazonaws.com"] }]
    condition = [
      {
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [var.bucket_arn]
      },
      {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.bucket_account_id]
      },
    ]
  }

  sns_send_statement = {
    sid        = "SnsSendMessage"
    effect     = "Allow"
    actions    = ["sqs:SendMessage"]
    principals = [{ type = "Service", identifiers = ["sns.amazonaws.com"] }]
    condition = [{
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.sns_topic_arn]
    }]
  }

  # This module owns neither the bucket notification nor the topic, so each
  # publisher is declared by the caller rather than inferred from the other.
  ingest_queue_publishers = merge(
    var.s3_notifies_ingest_queue ? { s3_send = local.s3_send_statement } : {},
    local.enabled.sns_delivery ? { sns_send = local.sns_send_statement } : {},
  )

  # A bucket notification normally targets the ingest queue, so this one gets an
  # S3 grant only when the caller says a notification points at it instead.
  auto_tagging_queue_publishers = merge(
    local.enabled.auto_tagging && var.auto_tagging.s3_notifies_queue ? { s3_send = local.s3_send_statement } : {},
    local.enabled.sns_delivery ? { sns_send = local.sns_send_statement } : {},
  )

  # A zero-statement document renders with no Statement key, which
  # SetQueueAttributes rejects, so a queue with no publisher falls back to the deny.
  ingest_queue_policy_statements = merge(
    local.ingest_queue_publishers,
    { for k, v in local.same_account_only_statements : k => v if length(local.ingest_queue_publishers) == 0 },
  )

  auto_tagging_queue_policy_statements = merge(
    local.auto_tagging_queue_publishers,
    { for k, v in local.same_account_only_statements : k => v if length(local.auto_tagging_queue_publishers) == 0 },
  )

  # Each glue stage subscribes to its own topic, not sns_delivery's, so neither
  # can reuse sns_send_statement. Here rather than inline in the module calls so
  # the policy sweep in tests/policies.tftest.hcl can see them.
  glue_topic_arns = merge(
    local.enabled.glue_create ? { glue_create = var.glue_create.sns_topic_arn } : {},
    local.enabled.glue_sync ? { glue_sync = var.glue_sync.sns_topic_arn } : {},
  )

  glue_queue_policy_statements = {
    for stage, topic_arn in local.glue_topic_arns : stage => {
      sns_send = {
        sid        = "SnsSendMessage"
        effect     = "Allow"
        actions    = ["sqs:SendMessage"]
        principals = [{ type = "Service", identifiers = ["sns.amazonaws.com"] }]
        condition = [{
          test     = "ArnEquals"
          variable = "aws:SourceArn"
          values   = [topic_arn]
        }]
      }
    }
  }

  # Per stage, so a new stage's log group can be adopted without touching the
  # ones a deployment already has.
  manage_log_group = {
    oxbow        = local.enabled.oxbow ? coalesce(var.oxbow.manage_log_group, var.manage_lambda_log_groups) : false
    group_events = local.enabled.group_events ? coalesce(var.group_events.manage_log_group, var.manage_lambda_log_groups) : false
    auto_tagging = local.enabled.auto_tagging ? coalesce(var.auto_tagging.manage_log_group, var.manage_lambda_log_groups) : false
    glue_create  = local.enabled.glue_create ? coalesce(var.glue_create.manage_log_group, var.manage_lambda_log_groups) : false
    glue_sync    = local.enabled.glue_sync ? coalesce(var.glue_sync.manage_log_group, var.manage_lambda_log_groups) : false
  }

  log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group"

  # A queue with no cross-service publisher needs no policy, but dropping one
  # from config leaves the old value in place: aws_sqs_queue.policy is computed.
  # So overwrite it with a deny. See UPGRADING for what that replaces.
  same_account_only_statements = {
    deny_outside_account = {
      sid        = "DenyOutsideAccount"
      effect     = "Deny"
      actions    = ["sqs:*"]
      principals = [{ type = "AWS", identifiers = ["*"] }]
      # Conditions are ANDed, so the IfExists forms keep the deny live on a
      # request carrying neither key while still exempting AWS acting for us.
      condition = [
        {
          test     = "StringNotEqualsIfExists"
          variable = "aws:PrincipalAccount"
          values   = [local.account_id]
        },
        {
          test     = "BoolIfExists"
          variable = "aws:PrincipalIsAWSService"
          values   = ["false"]
        },
      ]
    }
  }

  # No CreateLogGroup: the group exists whether OpenTofu creates it or the
  # lambda module's data source reads it, so no function ever creates one.
  lambda_logs_actions = ["logs:CreateLogStream", "logs:PutLogEvents"]

  # Oxbow and the group-events lambda share one role, so it needs the grouping
  # function's log group too. Every other stage's comes from the lambda module.

  group_events_log_group_arns = local.enabled.group_events ? [
    "${local.log_group_arn}:/aws/lambda/${var.group_events.lambda_function_name}:*",
    "${local.log_group_arn}:/aws/lambda/${var.group_events.lambda_function_name}:*:*",
  ] : []
}

# Only the limits AWS enforces at apply, where an over-length name fails after
# earlier resources have already changed. IAM, Athena and S3 names are validated
# client-side at plan, so an entry here could never fire.
locals {
  name_limits = merge(
    local.enabled.oxbow ? {
      "oxbow.lambda_function_name (Lambda, 64)" = [var.oxbow.lambda_function_name, 64]
      "oxbow.queue_name (SQS, 80)"              = [var.oxbow.queue_name, 80]
    } : {},
    # Null is config_guard's business: length(null) here buries its message.
    local.oxbow_standard_queue && var.oxbow.dl_queue_name != null ? {
      "oxbow.dl_queue_name (SQS, 80)" = [var.oxbow.dl_queue_name, 80]
    } : {},
    local.enabled.group_events ? {
      "group_events.lambda_function_name (Lambda, 64)" = [var.group_events.lambda_function_name, 64]
      "group_events.queue_name (SQS, 80)"              = [var.group_events.queue_name, 80]
      "group_events.dl_queue_name (SQS, 80)"           = [var.group_events.dl_queue_name, 80]
      "group_events FIFO queue name (SQS, 80)"         = [local.fifo_queue_name, 80]
      "group_events FIFO DLQ name (SQS, 80)"           = [local.fifo_dlq_name, 80]
    } : {},
    local.enabled.auto_tagging ? {
      "auto-tagging function name (Lambda, 64)" = [local.auto_tagging_function, 64]
      "auto-tagging queue name (SQS, 80)"       = [local.auto_tagging_queue_name, 80]
      "auto-tagging DLQ name (SQS, 80)"         = [local.auto_tagging_dlq_name, 80]
    } : {},
    local.enabled.glue_create ? {
      "glue_create.lambda_function_name (Lambda, 64)" = [var.glue_create.lambda_function_name, 64]
      "glue_create.sqs_queue_name (SQS, 80)"          = [var.glue_create.sqs_queue_name, 80]
      "glue_create.sqs_queue_name_dl (SQS, 80)"       = [var.glue_create.sqs_queue_name_dl, 80]
    } : {},
    local.enabled.glue_sync ? {
      "glue_sync.lambda_function_name (Lambda, 64)" = [var.glue_sync.lambda_function_name, 64]
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

# Preconditions, not variable validations: the stage objects already validate
# against each other, so a validation spanning them closes a cycle.
resource "terraform_data" "config_guard" {
  lifecycle {
    precondition {
      condition     = length(local.over_limit_names) == 0
      error_message = "Generated names exceed their AWS limit:\n${join("\n", local.over_limit_names)}"
    }

    precondition {
      condition     = !local.oxbow_standard_queue || var.oxbow.dl_queue_name != null
      error_message = "oxbow.dl_queue_name is required unless the group_events stage is on, which brings its own queues."
    }
  }
}
