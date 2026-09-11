# Optional auto-tagging stage: tags objects as they land, on its own queue and
# its own role so it can be enabled independently of oxbow.

module "auto_tagging_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "8.8.0"

  count = local.enabled.auto_tagging ? 1 : 0

  function_name = local.auto_tagging_function
  description   = var.lambda_description
  handler       = "provided"
  runtime       = "provided.al2023"
  architectures = var.architectures

  create_package = false
  s3_existing_package = {
    bucket = var.auto_tagging.lambda_s3_bucket
    key    = var.auto_tagging.lambda_s3_key
  }

  memory_size                    = var.lambda_memory_size
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  environment_variables = {
    UNWRAP_SNS_ENVELOPE = local.enabled.sns_delivery
  }

  role_name     = local.auto_tagging_role_name
  attach_policy = true
  policy        = aws_iam_policy.auto_tagging[0].arn

  use_existing_cloudwatch_log_group = !var.manage_lambda_log_groups
  cloudwatch_logs_retention_in_days = var.cloudwatch_logs_retention_in_days

  event_source_mapping = {
    sqs = {
      event_source_arn = module.auto_tagging_queue[0].queue_arn
    }
  }
  create_current_version_allowed_triggers = false

  tags = var.tags
}

module "auto_tagging_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  count = local.enabled.auto_tagging ? 1 : 0

  name                       = local.auto_tagging_queue_name
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  sqs_managed_sse_enabled    = var.sqs_managed_sse_enabled

  create_queue_policy     = true
  queue_policy_statements = local.auto_tagging_queue_policy_statements

  create_dlq                     = true
  dlq_name                       = local.auto_tagging_dlq_name
  dlq_delay_seconds              = 0
  dlq_visibility_timeout_seconds = 30
  redrive_policy                 = { maxReceiveCount = var.sqs_redrive_policy_maxReceiveCount }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}

resource "aws_sns_topic_subscription" "auto_tagging" {
  count = local.enabled.auto_tagging && local.enabled.sns_delivery ? 1 : 0

  topic_arn           = local.sns_topic_arn
  protocol            = "sqs"
  endpoint            = module.auto_tagging_queue[0].queue_arn
  filter_policy       = var.auto_tagging.filter_policy
  filter_policy_scope = var.auto_tagging.filter_policy_scope

  depends_on = [module.auto_tagging_queue]
}

resource "aws_lambda_permission" "auto_tagging" {
  count = local.enabled.auto_tagging ? 1 : 0

  statement_id   = "AllowExecutionFromS3Bucket"
  action         = "lambda:InvokeFunction"
  function_name  = module.auto_tagging_lambda[0].lambda_function_arn
  principal      = "s3.amazonaws.com"
  source_arn     = var.warehouse_bucket_arn
  source_account = local.warehouse_bucket_account_id
}

resource "aws_iam_policy" "auto_tagging" {
  count = local.enabled.auto_tagging ? 1 : 0

  name        = local.auto_tagging_policy
  description = "Auto-tagging lambda access to the warehouse prefix, its queue and the Delta lock tables"
  policy      = data.aws_iam_policy_document.auto_tagging[0].json
  tags        = var.tags
}

data "aws_iam_policy_document" "auto_tagging" {
  count = local.enabled.auto_tagging ? 1 : 0

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
    sid       = "ConsumeQueue"
    effect    = "Allow"
    actions   = local.sqs_consumer_actions
    resources = [module.auto_tagging_queue[0].queue_arn]
  }
}
