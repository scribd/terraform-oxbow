# Oxbow on its own, fed by a bucket notification the caller owns.

data "aws_caller_identity" "current" {}

# Both lock tables belong to the caller: they outlive any one pipeline, and
# delta-rs hard-codes "key" as the lock table's partition key.
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

  warehouse_bucket_arn = "arn:aws:s3:::${local.warehouse_bucket}"
  s3_path              = local.s3_path

  oxbow = {
    lambda_function_name = local.prefix
    lambda_s3_bucket     = "${local.prefix}-artifacts"
    lambda_s3_key        = "oxbow/oxbow-lambda.zip"
    role_name            = local.prefix
    policy_name          = local.prefix
    queue_name           = "${local.prefix}-queue"
    dl_queue_name        = "${local.prefix}-queue-dl"
  }

  aws_s3_locking_provider        = "dynamodb"
  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"

  dynamodb_table_name          = aws_dynamodb_table.oxbow_locking.name
  logstore_dynamodb_table_name = aws_dynamodb_table.delta_logstore.name

  tags = local.tags
}

# S3 permits one notification configuration per bucket, so it belongs to
# whoever owns the bucket rather than to the module.
resource "aws_s3_bucket_notification" "warehouse" {
  bucket = local.warehouse_bucket

  queue {
    queue_arn     = module.oxbow.ingest_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "${local.s3_path}/"
    filter_suffix = ".parquet"
  }
}
