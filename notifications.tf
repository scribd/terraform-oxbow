resource "aws_sns_topic_subscription" "oxbow" {
  count = local.from_sns ? 1 : 0

  topic_arn = var.sns_topic_arn
  protocol  = "sqs"
  endpoint  = local.ingest_queue_arn

  depends_on = [module.oxbow_queue, module.group_events_queue]
}

# Neither lambda is invoked by S3 in this module -- both are driven by an event
# source mapping off their queue -- but consumers wire buckets straight at these
# functions, so the permission stays. source_account closes the confused-deputy
# hole: bucket names are global, so a same-named bucket in another account could
# otherwise invoke.
resource "aws_lambda_permission" "oxbow_from_s3" {
  statement_id   = "AllowExecutionFromS3Bucket"
  action         = "lambda:InvokeFunction"
  function_name  = module.oxbow_lambda.lambda_function_arn
  principal      = "s3.amazonaws.com"
  source_arn     = var.warehouse_bucket_arn
  source_account = local.warehouse_bucket_account_id
}

# S3 supports a single notification configuration per bucket, so a bucket whose
# configuration is owned elsewhere must leave this off and add the queue there.
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification
resource "aws_s3_bucket_notification" "warehouse" {
  count = var.enable_bucket_notification ? 1 : 0

  bucket = var.warehouse_bucket_name

  queue {
    queue_arn     = local.ingest_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".parquet"
    filter_prefix = "${var.s3_path}/"
  }

  # S3 rejects a destination it cannot yet write to, and the queue policy is now
  # a separate resource -- referencing queue_arn alone does not order against it.
  depends_on = [module.oxbow_queue, module.group_events_queue]
}

resource "aws_glue_catalog_table" "oxbow" {
  count = var.enable_aws_glue_catalog_table ? 1 : 0

  name          = var.glue_table_name
  description   = var.glue_table_description
  database_name = var.glue_database_name

  parameters = {
    "classification" = "parquet"
  }

  storage_descriptor {
    location      = var.glue_location_uri
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      parameters = {
        "serialization.format" = "1"
      }
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = var.parquet_schema
      content {
        name       = columns.value.name
        parameters = try(columns.value.parameters, null)
        type       = columns.value.type
      }
    }
  }
}
