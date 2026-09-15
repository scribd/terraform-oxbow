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
    oxbow         = var.oxbow != null
    group_events  = var.group_events != null
    auto_tagging  = var.auto_tagging != null
    glue_create   = var.glue_create != null
    glue_sync     = var.glue_sync != null
    dl_monitoring = var.dead_letter_monitoring != null
    sns_delivery  = var.sns_delivery != null
  }

  sns_topic_arn = try(var.sns_delivery.topic_arn, null)

  # S3 bucket ARNs carry no account id, so a cross-account bucket has to name
  # its owner explicitly or the SourceAccount conditions reject it.
  bucket_account_id = coalesce(var.bucket_account_id, local.account_id)

  # Oxbow reads from the FIFO queue the group-events lambda feeds, or straight
  # from the standard queue when grouping is off. The queue S3 (or SNS)
  # delivers object-created events to is the group-events queue under grouping
  # and the same standard queue otherwise.
  fifo_queue_name = local.enabled.group_events ? "${trimsuffix(var.group_events.fifo_queue_name, ".fifo")}.fifo" : ""
  fifo_dlq_name   = local.enabled.group_events ? "${trimsuffix(var.group_events.fifo_dl_queue_name, ".fifo")}.fifo" : ""

  # The standard ingest queue belongs to the oxbow path, so it exists only when
  # oxbow does and grouping is off.
  oxbow_standard_queue = local.enabled.oxbow && !local.enabled.group_events

  oxbow_source_queue_name = local.enabled.group_events ? local.fifo_queue_name : try(var.oxbow.queue_name, null)
  ingest_queue_name       = local.enabled.group_events ? var.group_events.queue_name : try(var.oxbow.queue_name, null)

  oxbow_source_queue_arn = local.enabled.group_events ? module.oxbow_fifo_queue[0].queue_arn : try(module.oxbow_queue[0].queue_arn, null)
  ingest_queue_arn       = local.enabled.group_events ? module.group_events_queue[0].queue_arn : try(module.oxbow_queue[0].queue_arn, null)

  # Auto tagging names default to the oxbow names with a suffix, which is how
  # they have always been derived. Without oxbow there is nothing to derive
  # from, so its own name fields become required -- see its validation.
  auto_tagging_suffix     = "-auto_tagging"
  auto_tagging_function   = local.enabled.auto_tagging ? coalesce(var.auto_tagging.function_name, local.enabled.oxbow ? "${var.oxbow.lambda_function_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_role_name  = local.enabled.auto_tagging ? coalesce(var.auto_tagging.role_name, local.enabled.oxbow ? "${var.oxbow.role_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_policy     = local.enabled.auto_tagging ? coalesce(var.auto_tagging.policy_name, local.enabled.oxbow ? "${var.oxbow.policy_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_queue_name = local.enabled.auto_tagging ? coalesce(var.auto_tagging.queue_name, local.enabled.oxbow ? "${var.oxbow.queue_name}${local.auto_tagging_suffix}" : null) : null
  auto_tagging_dlq_name   = local.enabled.auto_tagging ? coalesce(var.auto_tagging.dl_queue_name, "${local.auto_tagging_queue_name}-dl") : null

  s3_prefix_arn = "${var.bucket_arn}/${var.s3_path}"

  dynamodb_table_arn_prefix = "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table"
  lock_table_arn            = "${local.dynamodb_table_arn_prefix}/${var.dynamodb_table_name}"
  logstore_table_arn        = "${local.dynamodb_table_arn_prefix}/${var.logstore_dynamodb_table_name}"

  # The set delta-rs documents for the DynamoDB locking provider, plus the
  # DescribeTable its client issues on init. Deliberately no CreateTable:
  # neither table is created here, both are existing inputs.
  # https://delta-io.github.io/delta-rs/usage/writing/writing-to-s3-with-locking-provider/
  expected_dynamodb_actions = [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:Query",
    "dynamodb:DescribeTable",
  ]

  delta_lock_table_arns = [local.lock_table_arn, local.logstore_table_arn]

  glue_catalog_resources = [
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/*",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/*",
  ]

  # Exactly AWSLambdaSQSQueueExecutionRole's SQS half. ChangeMessageVisibility
  # would only be needed for partial batch responses, which no event source
  # mapping here enables.
  sqs_consumer_actions = [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes",
  ]

  # Publishers of the object-created events, as reusable statements. Each queue
  # composes the set that actually writes to it, and both paths can be live at
  # once, so these are additive rather than either/or.
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

  # The two delivery paths are independent, and this module owns neither the
  # bucket notification nor the topic, so each is declared rather than inferred.
  # Both can be live at once.
  ingest_queue_publishers = merge(
    var.s3_notifies_ingest_queue ? { s3_send = local.s3_send_statement } : {},
    local.enabled.sns_delivery ? { sns_send = local.sns_send_statement } : {},
  )

  # A caller's bucket notification normally targets the ingest queue, so the
  # auto-tagging queue gets an S3 grant only when the caller says one points at
  # it instead.
  auto_tagging_queue_publishers = merge(
    local.enabled.auto_tagging && var.auto_tagging.s3_notifies_queue ? { s3_send = local.s3_send_statement } : {},
    local.enabled.sns_delivery ? { sns_send = local.sns_send_statement } : {},
  )

  # A queue with no cross-service publisher still needs a policy with at least
  # one statement: a zero-statement document renders as {"Version": ...} with no
  # Statement key, which SetQueueAttributes rejects as MalformedPolicyDocument.
  # The same-account deny is the right content for such a queue anyway.
  ingest_queue_policy_statements = merge(
    local.ingest_queue_publishers,
    { for k, v in local.same_account_only_statements : k => v if length(local.ingest_queue_publishers) == 0 },
  )

  auto_tagging_queue_policy_statements = merge(
    local.auto_tagging_queue_publishers,
    { for k, v in local.same_account_only_statements : k => v if length(local.auto_tagging_queue_publishers) == 0 },
  )

  # Each stage falls back to the module-wide default, so a deployment can adopt
  # a new stage's log group without touching the ones it already has.
  manage_log_group = {
    oxbow        = local.enabled.oxbow ? coalesce(var.oxbow.manage_log_group, var.manage_lambda_log_groups) : false
    group_events = local.enabled.group_events ? coalesce(var.group_events.manage_log_group, var.manage_lambda_log_groups) : false
    auto_tagging = local.enabled.auto_tagging ? coalesce(var.auto_tagging.manage_log_group, var.manage_lambda_log_groups) : false
    glue_create  = local.enabled.glue_create ? coalesce(var.glue_create.manage_log_group, var.manage_lambda_log_groups) : false
    glue_sync    = local.enabled.glue_sync ? coalesce(var.glue_sync.manage_log_group, var.manage_lambda_log_groups) : false
  }

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

# Lambda, SQS and DynamoDB name limits are enforced by AWS at apply, not at
# plan, so an over-length name fails mid-apply after earlier resources have
# already changed. The provider does validate IAM role, IAM policy, Athena
# workgroup and S3 bucket names client-side at plan, so those are deliberately
# absent here -- an entry that can never fire is one more number to get wrong.
locals {
  name_limits = merge(
    local.enabled.oxbow ? {
      "oxbow.lambda_function_name (Lambda, 64)" = [var.oxbow.lambda_function_name, 64]
      "oxbow.queue_name (SQS, 80)"              = [var.oxbow.queue_name, 80]
      "oxbow.dl_queue_name (SQS, 80)"           = [var.oxbow.dl_queue_name, 80]
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

resource "terraform_data" "name_length_guard" {
  lifecycle {
    precondition {
      condition     = length(local.over_limit_names) == 0
      error_message = "Generated names exceed their AWS limit:\n${join("\n", local.over_limit_names)}"
    }
  }
}
