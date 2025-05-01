
# glue-create lambda resource
module "glue_create_athena_workgroup_bucket" {
  count = var.enable_glue_create ? 1 : 0

  source                   = "terraform-aws-modules/s3-bucket/aws"
  version                  = "4.1.2"
  bucket                   = var.glue_create_config.athena_bucket_name
  block_public_acls        = true
  block_public_policy      = true
  ignore_public_acls       = true
  restrict_public_buckets  = true
  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"
  tags                     = var.tags
  versioning = {
    enabled = false
  }
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
  depends_on = [module.glue_create_athena_workgroup_bucket]
}

data "aws_iam_policy_document" "glue_create_sqs" {
  count = var.enable_glue_create ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    resources = ["arn:aws:sqs:*:*:${var.glue_create_config.sqs_queue_name}"]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.glue_create_config.sns_topic_arn]
    }
  }
}

data "aws_iam_policy_document" "glue_create_sqs_dl" {
  count = var.enable_glue_create ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
    resources = ["arn:aws:sqs:*:*:${var.glue_create_config.sqs_queue_name_dl}"]
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:sqs:*:*:${var.glue_create_config.sqs_queue_name}"]
    }
  }
}

resource "aws_sqs_queue" "glue_create" {
  count                      = var.enable_glue_create ? 1 : 0
  message_retention_seconds  = var.message_retention_seconds
  name                       = var.glue_create_config.sqs_queue_name
  policy                     = data.aws_iam_policy_document.glue_create_sqs[0].json
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  delay_seconds              = var.sqs_delay_seconds
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.glue_create_dl[0].arn
    maxReceiveCount     = var.sqs_redrive_policy_maxReceiveCount
  })
  tags = var.tags
}

resource "aws_sqs_queue" "glue_create_dl" {
  count                     = var.enable_glue_create ? 1 : 0
  message_retention_seconds = var.message_retention_seconds
  name                      = var.glue_create_config.sqs_queue_name_dl
  policy                    = data.aws_iam_policy_document.glue_create_sqs_dl[0].json
  tags                      = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "terraform_queue_redrive_allow_policy" {
  count = var.enable_glue_create ? 1 : 0

  queue_url = aws_sqs_queue.glue_create_dl[0].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue",
    sourceQueueArns   = [aws_sqs_queue.glue_create[0].arn]
  })
}

resource "aws_sns_topic_subscription" "glue_create_sns_sub" {
  count = var.enable_glue_create ? 1 : 0

  topic_arn = var.glue_create_config.sns_topic_arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.glue_create[0].arn
}

data "aws_iam_policy_document" "glue_create_assume" {
  count = var.enable_glue_create ? 1 : 0

  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
    ]
  }
}

data "aws_iam_policy_document" "glue_create" {
  count = var.enable_glue_create ? 1 : 0

  statement {
    sid = "AthenaWorkgroupAthenaRW"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
    ]
    resources = [
      aws_athena_workgroup.glue_create[0].arn
    ]
    effect = "Allow"
  }
  statement {
    sid    = "AthenaWorkgroupS3RW"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation"
    ]
    resources = [
      "${module.glue_create_athena_workgroup_bucket[0].s3_bucket_arn}/*",
      module.glue_create_athena_workgroup_bucket[0].s3_bucket_arn
    ]
  }
  statement {
    sid       = "AthenaWorkgroupList1"
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
      "glue:UpdateTable"
    ]
    resources = [
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/*",
      "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/*"
    ]
  }
  statement {
    sid    = "GlueCatalogAllowDatabases"
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:CreateDatabase"
    ]
    resources = [
      "*"
    ]
  }
  statement {
    sid    = "TableExtLocS3RO"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
      "s3:GetObjectVersion",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketVersions"
    ]
    resources = [
      var.warehouse_bucket_arn,
      "${var.warehouse_bucket_arn}/${var.s3_path}/*"
    ]
  }
  statement {
    effect    = "Allow"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.glue_create[0].arn]
  }
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_create_managed" {
  count = var.enable_glue_create ? 1 : 0

  name        = var.glue_create_config.iam_policy_name
  description = "Glue create policy allows access to Athena and S3"
  policy      = data.aws_iam_policy_document.glue_create[0].json
  tags        = var.tags
}

resource "aws_iam_role" "glue_create" {
  count = var.enable_glue_create ? 1 : 0

  name                = var.glue_create_config.iam_role_name
  assume_role_policy  = data.aws_iam_policy_document.glue_create_assume[0].json
  managed_policy_arns = [aws_iam_policy.glue_create_managed[0].arn]
  tags                = var.tags
}

resource "aws_lambda_function" "glue_create_lambda" {
  count         = var.enable_glue_create ? 1 : 0
  architectures = var.architectures
  description   = "Greate tables in AWS Glue catalog based on the table prefix"
  s3_key        = var.glue_create_config.lambda_s3_key
  s3_bucket     = var.glue_create_config.lambda_s3_bucket
  function_name = var.glue_create_config.lambda_function_name
  role          = aws_iam_role.glue_create[0].arn
  handler       = "provided"
  runtime       = "provided.al2023"
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout
  environment {
    variables = {
      RUST_LOG            = var.rust_log_oxbow_debug_level
      ATHENA_WORKGROUP    = var.glue_create_config.athena_workgroup_name
      ATHENA_DATA_SOURCE  = var.glue_create_config.athena_data_source
      GLUE_PATH_REGEX     = var.glue_create_config.path_regex
      UNWRAP_SNS_ENVELOPE = true
    }
  }
}

resource "aws_lambda_event_source_mapping" "glue_create" {
  count = var.enable_glue_create ? 1 : 0

  event_source_arn = aws_sqs_queue.glue_create[0].arn
  function_name    = aws_lambda_function.glue_create_lambda[0].arn
}
