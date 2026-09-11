# Optional glue-create stage: creates Glue catalog tables from the S3 path,
# running its DDL through a dedicated Athena workgroup.

module "glue_create_athena_workgroup_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.4"

  count = var.enable_glue_create ? 1 : 0

  bucket                   = var.glue_create_config.athena_bucket_name
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
  count = var.enable_glue_create ? 1 : 0

  name = var.glue_create_config.athena_workgroup_name
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

  count = var.enable_glue_create ? 1 : 0

  function_name = var.glue_create_config.lambda_function_name
  description   = "Create tables in the AWS Glue catalog based on the table prefix"
  handler       = "provided"
  runtime       = "provided.al2023"
  architectures = var.architectures

  create_package = false
  s3_existing_package = {
    bucket = var.glue_create_config.lambda_s3_bucket
    key    = var.glue_create_config.lambda_s3_key
  }

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout

  environment_variables = {
    RUST_LOG            = var.rust_log_oxbow_debug_level
    ATHENA_WORKGROUP    = var.glue_create_config.athena_workgroup_name
    ATHENA_DATA_SOURCE  = var.glue_create_config.athena_data_source
    GLUE_PATH_REGEX     = var.glue_create_config.path_regex
    UNWRAP_SNS_ENVELOPE = true
  }

  role_name     = var.glue_create_config.iam_role_name
  attach_policy = true
  policy        = aws_iam_policy.glue_create[0].arn

  use_existing_cloudwatch_log_group = !var.manage_lambda_log_groups
  cloudwatch_logs_retention_in_days = var.cloudwatch_logs_retention_in_days

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

  count = var.enable_glue_create ? 1 : 0

  name                       = var.glue_create_config.sqs_queue_name
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  sqs_managed_sse_enabled    = var.sqs_managed_sse_enabled

  create_queue_policy = true
  queue_policy_statements = {
    sns_send = {
      effect     = "Allow"
      actions    = ["sqs:SendMessage"]
      principals = [{ type = "Service", identifiers = ["sns.amazonaws.com"] }]
      condition = [{
        test     = "ArnEquals"
        variable = "aws:SourceArn"
        values   = [var.glue_create_config.sns_topic_arn]
      }]
    }
  }

  create_dlq                     = true
  dlq_name                       = var.glue_create_config.sqs_queue_name_dl
  dlq_delay_seconds              = 0
  dlq_visibility_timeout_seconds = 30
  redrive_policy                 = { maxReceiveCount = var.sqs_redrive_policy_maxReceiveCount }

  create_dlq_queue_policy     = true
  dlq_queue_policy_statements = local.same_account_only_statements

  tags = var.tags
}

resource "aws_sns_topic_subscription" "glue_create" {
  count = var.enable_glue_create ? 1 : 0

  # Empty strings are rejected by the provider; absent means "no filter".
  filter_policy       = var.glue_create_config.sns_subcription_filter_policy != "" ? var.glue_create_config.sns_subcription_filter_policy : null
  filter_policy_scope = var.glue_create_config.filter_policy_scope != "" ? var.glue_create_config.filter_policy_scope : null
  topic_arn           = var.glue_create_config.sns_topic_arn
  protocol            = "sqs"
  endpoint            = module.glue_create_queue[0].queue_arn
}

resource "aws_iam_policy" "glue_create" {
  count = var.enable_glue_create ? 1 : 0

  name        = var.glue_create_config.iam_policy_name
  description = "Glue create policy allows access to Athena, Glue and the warehouse prefix"
  policy      = data.aws_iam_policy_document.glue_create[0].json
  tags        = var.tags
}

data "aws_iam_policy_document" "glue_create" {
  count = var.enable_glue_create ? 1 : 0

  statement {
    sid    = "AthenaWorkgroupAthenaRW"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
    ]
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
    sid       = "AthenaListWorkgroups"
    effect    = "Allow"
    actions   = ["athena:ListWorkGroups"]
    resources = ["*"]
  }

  statement {
    sid    = "GlueAllowTables"
    effect = "Allow"
    actions = [
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable",
    ]
    resources = local.glue_catalog_resources
  }

  statement {
    sid       = "GlueCatalogAllowDatabases"
    effect    = "Allow"
    actions   = ["glue:GetDatabase", "glue:GetDatabases", "glue:CreateDatabase"]
    resources = local.glue_catalog_resources
  }

  statement {
    sid       = "TableExtLocS3RO"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:GetObjectTagging", "s3:GetObjectVersion"]
    resources = ["${local.warehouse_prefix_arn}/*"]
  }

  statement {
    sid       = "TableExtLocS3List"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketVersions"]
    resources = [var.warehouse_bucket_arn]
  }

  statement {
    sid    = "ConsumeQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [module.glue_create_queue[0].queue_arn]
  }
}

locals {
  glue_catalog_resources = [
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/*",
    "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/*",
  ]
}
