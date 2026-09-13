# Oxbow fed from an SNS topic rather than straight from the bucket, with
# glue-sync keeping the catalog in step. This is the shape logs-fastly and
# airbyte run.

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
    lambda_s3_bucket     = "${local.prefix}-artifacts"
    lambda_s3_key        = "oxbow/oxbow-lambda.zip"
    role_name            = local.prefix
    policy_name          = local.prefix
    queue_name           = "${local.prefix}-queue"
    dl_queue_name        = "${local.prefix}-queue-dl"
  }

  # Events arrive only through the topic, so the queue policy should not carry
  # an S3 grant nothing uses.
  sns_delivery = {
    topic_arn     = local.topic_arn
    filter_policy = jsonencode({ prefix = ["${local.s3_path}/"] })
  }
  s3_notifies_ingest_queue = false

  glue_sync = {
    lambda_s3_bucket     = "${local.prefix}-artifacts"
    lambda_s3_key        = "glue-sync/glue-sync.zip"
    lambda_function_name = "${local.prefix}-glue-sync"
    sns_topic_arn        = local.topic_arn
    sqs_queue_name       = "${local.prefix}-glue-sync"
    sqs_queue_name_dl    = "${local.prefix}-glue-sync-dl"
    iam_role_name        = "${local.prefix}-glue-sync"
    iam_policy_name      = "${local.prefix}-glue-sync"
  }

  aws_s3_locking_provider        = "dynamodb"
  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"

  dynamodb_table_name          = aws_dynamodb_table.oxbow_locking.name
  logstore_dynamodb_table_name = aws_dynamodb_table.delta_logstore.name

  tags = local.tags
}
