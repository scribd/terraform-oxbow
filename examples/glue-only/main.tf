# oxbow = null. The Delta tables are written by something else; this deployment
# only keeps the Glue catalog in step with them. glue_create and glue_sync each
# carry their own queue, role and policy, so neither needs the oxbow stage.

module "oxbow" {
  source = "../../"

  warehouse_bucket_arn = "arn:aws:s3:::${local.warehouse_bucket}"
  s3_path              = local.s3_path

  oxbow = null

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

  dead_letter_monitoring = {
    critical         = 2
    alert_recipients = ["@slack-data-platform"]
    tags             = ["env:${local.env}", "service:oxbow-glue"]
  }

  rust_log_oxbow_debug_level = "info"

  # Required by the module's interface but unused here: nothing in this
  # deployment reads the Delta log or takes a lock. See the README note.
  rust_log_deltalake_debug_level = "info"
  aws_s3_locking_provider        = "dynamodb"
  dynamodb_table_name            = "unused-by-this-deployment"
  logstore_dynamodb_table_name   = "unused-by-this-deployment"

  tags = local.tags
}
