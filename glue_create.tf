# Optional glue-create stage: creates Glue catalog tables from the S3 path,
# running its DDL through a dedicated Athena workgroup.

module "glue_create_athena_workgroup_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.4"

  count = local.enabled.glue_create ? 1 : 0

  bucket                   = var.glue_create.athena_bucket_name
  block_public_acls        = true
  block_public_policy      = true
  ignore_public_acls       = true
  restrict_public_buckets  = true
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"
  versioning               = { enabled = false }

  tags = var.tags
}

resource "aws_athena_workgroup" "glue_create" {
  count = local.enabled.glue_create ? 1 : 0

  name = var.glue_create.athena_workgroup_name
  tags = var.tags

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${module.glue_create_athena_workgroup_bucket[0].s3_bucket_id}/"
    }
  }
}

module "glue_create_lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "8.8.0"

  count = local.enabled.glue_create ? 1 : 0

  function_name = var.glue_create.lambda_function_name
  description   = "Create tables in the AWS Glue catalog based on the table prefix"
  handler       = "provided"
  runtime       = "provided.al2023"
  architectures = var.architectures

  create_package = false
  s3_existing_package = {
    bucket = var.glue_create.lambda_s3_bucket
    key    = var.glue_create.lambda_s3_key
  }

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout

  environment_variables = {
    RUST_LOG            = var.rust_log_oxbow_debug_level
    ATHENA_WORKGROUP    = var.glue_create.athena_workgroup_name
    ATHENA_DATA_SOURCE  = var.glue_create.athena_data_source
    GLUE_PATH_REGEX     = var.glue_create.path_regex
    UNWRAP_SNS_ENVELOPE = "true"
  }

  role_name     = var.glue_create.iam_role_name
  attach_policy = true
  policy        = aws_iam_policy.glue_create[0].arn

  use_existing_cloudwatch_log_group  = !local.manage_log_group.glue_create
  attach_create_log_group_permission = false
  cloudwatch_logs_retention_in_days  = var.cloudwatch_logs_retention_in_days

  event_source_mapping = {
    sqs = {
      event_source_arn = module.glue_create_queue[0].queue_arn
    }
  }
  create_current_version_allowed_triggers = false

  tags = var.tags
}

module "glue_create_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "5.2.2"

  count = local.enabled.glue_create ? 1 : 0

  name                       = var.glue_create.sqs_queue_name
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  sqs_managed_sse_enabled    = var.sqs_managed_sse_enabled

  create_queue_policy     = true
  queue_policy_statements = local.glue_queue_policy_statements["glue_create"]

  create_dlq                     = true
  dlq_name                       = var.glue_create.sqs_queue_name_dl
  dlq_message_retention_seconds  = var.message_retention_seconds
  dlq_delay_seconds              = 0
  dlq_visibility_timeout_seconds = 30
  redrive_policy                 = { maxReceiveCount = var.sqs_redrive_policy_maxReceiveCount }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}

resource "aws_sns_topic_subscription" "glue_create" {
  count = local.enabled.glue_create ? 1 : 0

  filter_policy       = var.glue_create.filter_policy
  filter_policy_scope = var.glue_create.filter_policy_scope
  topic_arn           = var.glue_create.sns_topic_arn
  protocol            = "sqs"
  endpoint            = module.glue_create_queue[0].queue_arn

  depends_on = [module.glue_create_queue]
}

resource "aws_iam_policy" "glue_create" {
  count = local.enabled.glue_create ? 1 : 0

  name        = var.glue_create.iam_policy_name
  description = "Glue create policy allows access to Athena, Glue and the configured prefix"
  policy      = data.aws_iam_policy_document.glue_create[0].json
  tags        = var.tags
}

data "aws_iam_policy_document" "glue_create" {
  count = local.enabled.glue_create ? 1 : 0

  statement {
    sid       = "AthenaRunDDL"
    effect    = "Allow"
    actions   = local.athena_actions
    resources = [aws_athena_workgroup.glue_create[0].arn]
  }

  statement {
    sid    = "AthenaWorkgroupS3RW"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
    ]
    resources = [
      module.glue_create_athena_workgroup_bucket[0].s3_bucket_arn,
      "${module.glue_create_athena_workgroup_bucket[0].s3_bucket_arn}/*",
    ]
  }

  statement {
    sid       = "GlueCreateTablesAndDatabases"
    effect    = "Allow"
    actions   = local.glue_create_actions
    resources = local.glue_catalog_resources
  }

  statement {
    sid       = "TableExtLocS3RO"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectTagging", "s3:GetObjectVersion"]
    resources = ["${local.s3_prefix_arn}/*"]
  }

  statement {
    sid       = "TableExtLocS3List"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketVersions"]
    resources = [var.bucket_arn]
  }

  statement {
    sid       = "ConsumeQueue"
    effect    = "Allow"
    actions   = local.sqs_consumer_actions
    resources = [module.glue_create_queue[0].queue_arn]
  }
}
