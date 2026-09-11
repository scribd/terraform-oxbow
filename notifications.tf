resource "aws_sns_topic_subscription" "oxbow" {
  count = local.enabled.sns_delivery ? 1 : 0

  topic_arn           = local.sns_topic_arn
  protocol            = "sqs"
  endpoint            = local.ingest_queue_arn
  filter_policy       = var.sns_delivery.filter_policy
  filter_policy_scope = var.sns_delivery.filter_policy_scope

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

resource "aws_s3_bucket_notification" "warehouse" {
  count = local.enabled.bucket_notification ? 1 : 0

  bucket = var.warehouse_bucket_name

  queue {
    queue_arn     = local.ingest_queue_arn
    events        = var.bucket_notification.events
    filter_prefix = coalesce(var.bucket_notification.filter_prefix, "${var.s3_path}/")
    filter_suffix = var.bucket_notification.filter_suffix
  }

  # S3 rejects a destination it cannot yet write to, and the queue policy is now
  # a separate resource -- referencing queue_arn alone does not order against it.
  depends_on = [module.oxbow_queue, module.group_events_queue]
}

resource "aws_glue_catalog_table" "oxbow" {
  count = local.enabled.glue_catalog_table ? 1 : 0

  name          = var.glue_catalog_table.table_name
  description   = var.glue_catalog_table.description
  database_name = var.glue_catalog_table.database_name

  parameters = {
    "classification" = "parquet"
  }

  storage_descriptor {
    location      = var.glue_catalog_table.location_uri
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      parameters = {
        "serialization.format" = "1"
      }
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    dynamic "columns" {
      for_each = var.glue_catalog_table.columns
      content {
        name       = columns.value.name
        parameters = columns.value.parameters
        type       = columns.value.type
      }
    }
  }
}
