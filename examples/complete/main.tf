# Every stage on: events grouped by table prefix before oxbow sees them,
# objects auto-tagged as they land, the Glue catalog created and kept in step,
# and a Datadog monitor per dead letter queue.

resource "aws_dynamodb_table" "oxbow_locking" {
  name         = "${local.prefix}-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  ttl {
    attribute_name = "leaseDuration"
    enabled        = true
  }

  attribute {
    name = "key"
    type = "S"
  }

  tags = local.tags
}

resource "aws_dynamodb_table" "delta_logstore" {
  name         = "${local.prefix}-logstore"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "tablePath"
  range_key    = "fileName"

  attribute {
    name = "tablePath"
    type = "S"
  }

  attribute {
    name = "fileName"
    type = "S"
  }

  tags = local.tags
}

module "oxbow" {
  source = "../../"

  bucket_arn = "arn:aws:s3:::${local.bucket}"
  s3_path    = local.s3_path

  oxbow = {
    lambda_function_name = local.prefix
    lambda_s3_bucket     = local.artifacts
    lambda_s3_key        = "oxbow/oxbow-lambda.zip"
    role_name            = local.prefix
    policy_name          = local.prefix
    queue_name           = "${local.prefix}-queue"
  }

  # With grouping on, S3 events land on queue_name and oxbow reads the FIFO
  # queue this lambda feeds instead of its own — so oxbow needs no dl_queue_name.
  group_events = {
    lambda_function_name = "${local.prefix}-group-events"
    lambda_s3_bucket     = local.artifacts
    lambda_s3_key        = "group-events/group-events.zip"
    queue_name           = "${local.prefix}-group-events"
    dl_queue_name        = "${local.prefix}-group-events-dl"
    fifo_queue_name      = "${local.prefix}-fifo"
    fifo_dl_queue_name   = "${local.prefix}-fifo-dl"
    timeout              = 60
    memory_size          = 256
  }

  auto_tagging = {
    lambda_s3_bucket = local.artifacts
    lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    filter_policy = jsonencode({
      Records = { s3 = { object = { key = [{ prefix = "${local.s3_path}/" }] } } }
    })
    filter_policy_scope = "MessageBody"
  }

  glue_create = {
    athena_workgroup_name = "${local.prefix}-glue-create"
    athena_data_source    = "AwsDataCatalog"
    athena_bucket_name    = "${local.prefix}-athena-results"
    lambda_s3_bucket      = local.artifacts
    lambda_s3_key         = "glue-create/glue-create.zip"
    lambda_function_name  = "${local.prefix}-glue-create"
    path_regex            = "^catalogs/(?<database>[^/]+)/(?<table>[^/]+)"
    sns_topic_arn         = local.topic_arn
    sqs_queue_name        = "${local.prefix}-glue-create"
    sqs_queue_name_dl     = "${local.prefix}-glue-create-dl"
    iam_role_name         = "${local.prefix}-glue-create"
    iam_policy_name       = "${local.prefix}-glue-create"
  }

  glue_sync = {
    lambda_s3_bucket     = local.artifacts
    lambda_s3_key        = "glue-sync/glue-sync.zip"
    lambda_function_name = "${local.prefix}-glue-sync"
    path_regex           = "^catalogs/(?<database>[^/]+)/(?<table>[^/]+)"
    sns_topic_arn        = local.topic_arn
    sqs_queue_name       = "${local.prefix}-glue-sync"
    sqs_queue_name_dl    = "${local.prefix}-glue-sync-dl"
    iam_role_name        = "${local.prefix}-glue-sync"
    iam_policy_name      = "${local.prefix}-glue-sync"
  }

  sns_delivery = {
    topic_arn = local.topic_arn
  }
  s3_notifies_ingest_queue = false

  dead_letter_monitoring = {
    critical         = 2
    warning          = 1
    alert_recipients = ["@slack-data-platform"]
    tags             = ["env:${local.env}", "service:oxbow"]
    query_conditions = "env:${local.env}"
  }

  aws_s3_locking_provider        = "dynamodb"
  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"

  dynamodb_table_name          = aws_dynamodb_table.oxbow_locking.name
  logstore_dynamodb_table_name = aws_dynamodb_table.delta_logstore.name

  manage_lambda_log_groups          = true
  cloudwatch_logs_retention_in_days = 30

  tags = local.tags
}
