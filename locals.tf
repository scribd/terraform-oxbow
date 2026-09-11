data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  group_events = var.enable_group_events
  from_sns     = var.sns_topic_arn != ""

  # Oxbow reads from the FIFO queue the group-events lambda feeds, or straight
  # from the standard queue when grouping is off. The queue S3 (or SNS)
  # delivers object-created events to is the group-events queue under grouping
  # and the same standard queue otherwise.
  fifo_queue_name         = "${trimsuffix(var.sqs_fifo_queue_name, ".fifo")}.fifo"
  oxbow_source_queue_name = local.group_events ? local.fifo_queue_name : var.sqs_queue_name
  ingest_queue_name       = local.group_events ? var.sqs_group_queue_name : var.sqs_queue_name

  oxbow_source_queue_arn = local.group_events ? module.oxbow_fifo_queue[0].queue_arn : module.oxbow_queue[0].queue_arn
  ingest_queue_arn       = local.group_events ? module.group_events_queue[0].queue_arn : module.oxbow_queue[0].queue_arn

  auto_tagging_queue_name = "${var.sqs_queue_name}-auto_tagging"
  auto_tagging_function   = "${var.lambda_function_name}-auto_tagging"
  auto_tagging_role_name  = "${var.oxbow_lambda_role_name}-auto_tagging"
  auto_tagging_policy     = "${var.lambda_permissions_policy_name}-auto_tagging"

  warehouse_prefix_arn = "${var.warehouse_bucket_arn}/${var.s3_path}"

  logstore_table_arn = "arn:${local.partition}:dynamodb:${local.region}:${local.account_id}:table/${var.logstore_dynamodb_table_name}"

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
      condition = [{
        test     = "StringNotEquals"
        variable = "aws:PrincipalAccount"
        values   = [local.account_id]
      }]
    }
  }

  # Oxbow and the group-events lambda share one role, so that role needs the
  # group-events log group too; every other lambda's logs policy comes from the
  # lambda module and is already scoped to its own group.
  group_events_log_group_arns = local.group_events ? [
    "${local.log_group_arn}:/aws/lambda/${var.events_lambda_function_name}:*",
    "${local.log_group_arn}:/aws/lambda/${var.events_lambda_function_name}:*:*",
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
    local.group_events ? {
      "events_lambda_function_name (Lambda, 64)" = [var.events_lambda_function_name, 64]
      "sqs_fifo_queue_name + .fifo (SQS, 80)"    = ["${var.sqs_fifo_queue_name}.fifo", 80]
      "sqs_fifo_DL_queue_name + .fifo (SQS, 80)" = ["${var.sqs_fifo_DL_queue_name}.fifo", 80]
      "sqs_group_queue_name (SQS, 80)"           = [var.sqs_group_queue_name, 80]
      "sqs_group_DL_queue_name (SQS, 80)"        = [var.sqs_group_DL_queue_name, 80]
    } : {},
    var.enable_auto_tagging ? {
      "auto-tagging function name (Lambda, 64)" = [local.auto_tagging_function, 64]
      "auto-tagging role name (IAM role, 64)"   = [local.auto_tagging_role_name, 64]
      "auto-tagging policy name (IAM, 64)"      = [local.auto_tagging_policy, 64]
      "auto-tagging queue name (SQS, 80)"       = [local.auto_tagging_queue_name, 80]
      "auto-tagging DLQ name (SQS, 80)"         = ["${local.auto_tagging_queue_name}-dl", 80]
    } : {},
    var.enable_glue_create ? {
      "glue_create lambda_function_name (Lambda, 64)" = [var.glue_create_config.lambda_function_name, 64]
      "glue_create iam_role_name (IAM role, 64)"      = [var.glue_create_config.iam_role_name, 64]
      "glue_create iam_policy_name (IAM, 64)"         = [var.glue_create_config.iam_policy_name, 64]
      "glue_create sqs_queue_name (SQS, 80)"          = [var.glue_create_config.sqs_queue_name, 80]
      "glue_create sqs_queue_name_dl (SQS, 80)"       = [var.glue_create_config.sqs_queue_name_dl, 80]
    } : {},
    var.enable_glue_sync ? {
      "glue_sync lambda_function_name (Lambda, 64)" = [var.glue_sync_config.lambda_function_name, 64]
      "glue_sync iam_role_name (IAM role, 64)"      = [var.glue_sync_config.iam_role_name, 64]
      "glue_sync iam_policy_name (IAM, 64)"         = [var.glue_sync_config.iam_policy_name, 64]
      "glue_sync sqs_queue_name (SQS, 80)"          = [var.glue_sync_config.sqs_queue_name, 80]
      "glue_sync sqs_queue_name_dl (SQS, 80)"       = [var.glue_sync_config.sqs_queue_name_dl, 80]
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
