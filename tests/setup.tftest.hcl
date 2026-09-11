# Shared provider mocks are declared per file; this file asserts the baseline
# wiring every other test builds on.

mock_provider "aws" {
  # Identity data the module interpolates into ARNs, pinned so tests can assert
  # on the ARNs it builds.
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }
  override_data {
    target = data.aws_region.current
    values = { region = "us-east-2" }
  }
  override_data {
    target = data.aws_partition.current
    values = { partition = "aws" }
  }

  # aws_iam_role and aws_iam_policy validate their JSON client-side, so the
  # mocked document has to parse. Policy content is therefore asserted against
  # the structured inputs rather than against rendered JSON.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # Attachments and the lambda's role reference validate the ARN shape, so a
  # generated placeholder will not do.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock"
    }
  }
}

mock_provider "datadog" {}

variables {
  warehouse_bucket_arn  = "arn:aws:s3:::scribdinc-data-lake-test"
  warehouse_bucket_name = "scribdinc-data-lake-test"
  s3_path               = "catalogs/bronze_monolith"

  lambda_function_name           = "test-oxbow"
  lambda_s3_bucket               = "test-artifacts"
  lambda_s3_key                  = "oxbow/oxbow-lambda.zip"
  oxbow_lambda_role_name         = "test-oxbow-role"
  lambda_permissions_policy_name = "test-oxbow-policy"

  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"
  aws_s3_locking_provider        = "dynamodb"

  dynamodb_table_name          = "test-oxbow-lock"
  logstore_dynamodb_table_name = "test-delta-logstore"

  sqs_queue_name    = "test-oxbow-queue"
  sqs_queue_name_dl = "test-oxbow-queue-dl"
}

run "minimal_deployment" {
  command = plan

  assert {
    condition     = module.oxbow_lambda.lambda_function_name == "test-oxbow"
    error_message = "Oxbow function name should come straight from lambda_function_name"
  }

  assert {
    condition     = length(module.oxbow_queue) == 1 && length(module.oxbow_fifo_queue) == 0
    error_message = "With grouping off the standard queue is created and the FIFO queue is not"
  }

  assert {
    condition     = local.oxbow_source_queue_name == local.ingest_queue_name
    error_message = "With grouping off one queue both receives events and feeds oxbow"
  }

  assert {
    condition     = length(module.group_events_lambda) == 0 && length(module.group_events_queue) == 0
    error_message = "Group events resources must not exist when enable_group_events is false"
  }

  assert {
    condition     = length(module.auto_tagging_lambda) == 0
    error_message = "Auto tagging must be off by default"
  }

  assert {
    condition     = length(module.glue_create_lambda) == 0 && length(module.glue_sync_lambda) == 0
    error_message = "Glue lambdas must be off by default"
  }

  assert {
    condition     = length(aws_glue_catalog_table.oxbow) == 0
    error_message = "Glue catalog table must be off by default"
  }

  assert {
    condition     = length(aws_s3_bucket_notification.warehouse) == 0
    error_message = "Bucket notification must be off by default"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.oxbow) == 0
    error_message = "No SNS subscription without sns_topic_arn"
  }

  assert {
    condition     = length(datadog_monitor.dead_letters) == 0
    error_message = "Dead letter monitoring must be off by default"
  }

  assert {
    condition     = aws_dynamodb_table.oxbow_locking.hash_key == "key"
    error_message = "delta-rs hard-codes 'key' as the lock table partition key"
  }

  assert {
    condition     = aws_dynamodb_table.oxbow_locking.billing_mode == "PAY_PER_REQUEST"
    error_message = "Lock table must stay on-demand"
  }
}

run "oxbow_environment_without_sns" {
  command = plan

  assert {
    condition     = module.oxbow_lambda.lambda_function_name == "test-oxbow"
    error_message = "Function name mismatch"
  }

  assert {
    condition     = local.oxbow_environment["RUST_LOG"] == "deltalake=info,oxbow=info"
    error_message = "RUST_LOG must combine both crate levels"
  }

  assert {
    condition     = local.oxbow_environment["DYNAMO_LOCK_TABLE_NAME"] == "test-oxbow-lock"
    error_message = "Oxbow must be pointed at the lock table this module creates"
  }

  assert {
    condition     = local.oxbow_environment["DELTA_DYNAMO_TABLE_NAME"] == "test-delta-logstore"
    error_message = "Oxbow must be pointed at the external logstore table"
  }

  assert {
    condition     = !contains(keys(local.oxbow_environment), "UNWRAP_SNS_ENVELOPE")
    error_message = "UNWRAP_SNS_ENVELOPE must be absent when events come straight from S3"
  }

  assert {
    condition     = local.oxbow_environment["SCHEMA_EVOLUTION"] == true
    error_message = "Schema evolution is on by default"
  }
}

run "schema_evolution_can_be_disabled" {
  command = plan

  variables {
    enable_schema_evolution = false
  }

  assert {
    condition     = !contains(keys(local.oxbow_environment), "SCHEMA_EVOLUTION")
    error_message = "SCHEMA_EVOLUTION must be omitted entirely, not set to false"
  }
}

run "sns_delivery_sets_unwrap_and_subscribes" {
  command = plan

  variables {
    sns_topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
  }

  assert {
    condition     = local.oxbow_environment["UNWRAP_SNS_ENVELOPE"] == true
    error_message = "Oxbow must unwrap the SNS envelope when fed from a topic"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.oxbow) == 1
    error_message = "The ingest queue must be subscribed to the topic"
  }

  assert {
    condition     = contains(keys(local.ingest_queue_policy_statements), "sns_send")
    error_message = "The queue policy must admit SNS, not S3, when fed from a topic"
  }

  assert {
    condition     = local.ingest_queue_policy_statements["sns_send"].condition[0].values == ["arn:aws:sns:us-east-2:123456789012:warehouse-events"]
    error_message = "The queue policy must be scoped to the configured topic"
  }
}

run "s3_delivery_scopes_queue_policy_to_bucket_and_account" {
  command = plan

  assert {
    condition     = contains(keys(local.ingest_queue_policy_statements), "s3_send")
    error_message = "The queue policy must admit S3 when there is no topic"
  }

  assert {
    condition     = local.ingest_queue_policy_statements["s3_send"].principals[0].identifiers == ["s3.amazonaws.com"]
    error_message = "The S3 service principal must be named rather than a wildcard"
  }

  assert {
    condition = anytrue([
      for c in local.ingest_queue_policy_statements["s3_send"].condition :
      c.variable == "aws:SourceAccount" && c.values == ["123456789012"]
    ])
    error_message = "The S3 statement must carry a SourceAccount condition to prevent the confused deputy"
  }

  assert {
    condition = alltrue([
      for s in values(local.ingest_queue_policy_statements) :
      !contains(s.actions, "sqs:ReceiveMessage")
    ])
    error_message = "No resource policy may hand sqs:ReceiveMessage to a foreign principal"
  }
}

run "bucket_notification_filters_on_the_configured_prefix" {
  command = plan

  variables {
    enable_bucket_notification = true
  }

  assert {
    condition     = length(aws_s3_bucket_notification.warehouse) == 1
    error_message = "Bucket notification should be created when enabled"
  }

  assert {
    condition     = one(aws_s3_bucket_notification.warehouse).bucket == "scribdinc-data-lake-test"
    error_message = "Notification must target the warehouse bucket"
  }

  assert {
    condition = alltrue([
      for q in one(aws_s3_bucket_notification.warehouse).queue :
      q.filter_prefix == "catalogs/bronze_monolith/" && q.filter_suffix == ".parquet"
    ])
    error_message = "Notification must be filtered to parquet objects under s3_path"
  }
}
