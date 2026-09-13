# Optional grouping stage. S3 events land on a standard queue, this lambda
# batches them by table prefix and republishes onto a FIFO queue, which is what
# oxbow then consumes.

module "group_events_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "8.8.0"

  count = local.enabled.group_events ? 1 : 0

  function_name = var.group_events.lambda_function_name
  description   = "Group events for oxbow based on the table prefix"
  handler       = "provided"
  runtime       = "provided.al2023"
  architectures = var.architectures

  create_package = false
  s3_existing_package = {
    bucket = var.group_events.lambda_s3_bucket
    key    = var.group_events.lambda_s3_key
  }

  memory_size = var.group_events.memory_size
  timeout     = var.group_events.timeout

  environment_variables = merge(
    {
      RUST_LOG  = var.rust_log_oxbow_debug_level
      QUEUE_URL = module.oxbow_fifo_queue[0].queue_url
    },
    local.enabled.sns_delivery ? { UNWRAP_SNS_ENVELOPE = true } : {},
  )

  # Shares the oxbow role, which is why that role carries this function's log
  # group in its policy statements.
  create_role = false
  lambda_role = module.oxbow_lambda[0].lambda_role_arn

  use_existing_cloudwatch_log_group = !var.manage_lambda_log_groups
  cloudwatch_logs_retention_in_days = var.cloudwatch_logs_retention_in_days

  event_source_mapping = {
    sqs = {
      event_source_arn                   = module.group_events_queue[0].queue_arn
      batch_size                         = var.group_events.batch_size
      maximum_batching_window_in_seconds = var.group_events.maximum_batching_window_in_seconds
    }
  }
  create_current_version_allowed_triggers = false

  tags = var.tags
}

module "group_events_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  count = local.enabled.group_events ? 1 : 0

  name                       = local.ingest_queue_name
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  sqs_managed_sse_enabled    = var.sqs_managed_sse_enabled

  create_queue_policy     = true
  queue_policy_statements = local.ingest_queue_policy_statements

  create_dlq                     = true
  dlq_name                       = var.group_events.dl_queue_name
  dlq_delay_seconds              = 0
  dlq_visibility_timeout_seconds = 30
  redrive_policy                 = { maxReceiveCount = var.group_events.max_receive_count }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}

module "oxbow_fifo_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  count = local.enabled.group_events ? 1 : 0

  name                        = local.fifo_queue_name
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = var.message_retention_seconds
  visibility_timeout_seconds  = var.sqs_visibility_timeout_seconds
  delay_seconds               = var.sqs_delay_seconds
  sqs_managed_sse_enabled     = var.sqs_managed_sse_enabled

  # Only the group-events lambda writes here, and it does so through its IAM
  # role.
  create_queue_policy     = true
  queue_policy_statements = local.same_account_only_statements

  create_dlq = true
  dlq_name   = local.fifo_dlq_name
  # The sqs module coalesces these from the primary queue, which would flip the
  # live DLQ's dedup flag. Not covered by tofu test: assertions cannot reach a
  # child module's resources.
  dlq_content_based_deduplication = false
  dlq_delay_seconds               = 0
  dlq_visibility_timeout_seconds  = 30
  redrive_policy                  = { maxReceiveCount = var.group_events.max_receive_count }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}
