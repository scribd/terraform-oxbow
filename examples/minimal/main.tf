# Oxbow on its own, fed by a bucket notification the caller owns.

# The lock table belongs to the caller: it outlives any one pipeline, and the
# dynamodb_lock crate hard-codes "key" as its partition key.
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

  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"

  dynamodb_table_name = aws_dynamodb_table.oxbow_locking.name

  # Greenfield: nothing has created these log groups yet, so the module must.
  manage_lambda_log_groups = true

  tags = local.tags
}

# S3 permits one notification configuration per bucket, so it belongs to
# whoever owns the bucket rather than to the module.
resource "aws_s3_bucket_notification" "warehouse" {
  bucket = local.bucket

  queue {
    queue_arn     = module.oxbow.ingest_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "${local.s3_path}/"
    filter_suffix = ".parquet"
  }

  # ingest_queue_arn resolves from the queue, not its policy, so without this
  # S3 can reject the destination it cannot yet write to.
  depends_on = [module.oxbow]
}
