resource "aws_sns_topic_subscription" "oxbow" {
  count = local.from_sns ? 1 : 0

  topic_arn = var.sns_topic_arn
  protocol  = "sqs"
  endpoint  = local.ingest_queue_arn
}

resource "aws_lambda_permission" "oxbow_from_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = module.oxbow_lambda.lambda_function_arn
  principal     = "s3.amazonaws.com"
  source_arn    = var.warehouse_bucket_arn
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

  depends_on = [aws_lambda_permission.oxbow_from_s3]
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
