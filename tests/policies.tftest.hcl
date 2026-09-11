# One test per policy defect found while auditing the rewrite. Each name says
# what went wrong; each would fail if the defect were reintroduced.

mock_provider "aws" {
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

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

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

# Previously the policy was `from_sns ? sns_statement : s3_statement`, so a
# deployment with both a topic and enable_bucket_notification admitted SNS only
# and S3 deliveries were rejected with no visible error.
run "both_delivery_paths_are_admitted_when_both_are_configured" {
  command = plan

  variables {
    enable_bucket_notification = true
    sns_topic_arn              = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
  }

  assert {
    condition     = contains(keys(local.ingest_queue_policy_statements), "s3_send")
    error_message = "S3 notifies the queue directly here, so the policy must admit S3"
  }

  assert {
    condition     = contains(keys(local.ingest_queue_policy_statements), "sns_send")
    error_message = "The queue is also subscribed to the topic, so the policy must admit SNS"
  }
}

run "sns_only_deployment_does_not_admit_s3" {
  command = plan

  variables {
    enable_bucket_notification = false
    sns_topic_arn              = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
  }

  assert {
    condition     = keys(local.ingest_queue_policy_statements) == ["sns_send"]
    error_message = "With delivery only via SNS, S3 must not be granted SendMessage"
  }
}

# aws:SourceAccount was hardcoded to the deploying account, which rejects every
# event from a warehouse bucket owned by another account.
run "cross_account_warehouse_bucket_is_supported" {
  command = plan

  variables {
    warehouse_bucket_account_id = "210987654321"
  }

  assert {
    condition = anytrue([
      for c in local.ingest_queue_policy_statements["s3_send"].condition :
      c.variable == "aws:SourceAccount" && c.values == ["210987654321"]
    ])
    error_message = "SourceAccount must name the bucket owner, not the deploying account"
  }

  assert {
    condition     = aws_lambda_permission.oxbow_from_s3.source_account == "210987654321"
    error_message = "The lambda permission must be scoped to the bucket owner too"
  }
}

run "warehouse_bucket_account_defaults_to_this_account" {
  command = plan

  assert {
    condition     = local.warehouse_bucket_account_id == "123456789012"
    error_message = "Omitting the variable must keep the current account"
  }
}

run "non_numeric_account_id_is_rejected" {
  command = plan

  variables {
    warehouse_bucket_account_id = "not-an-account"
  }

  expect_failures = [var.warehouse_bucket_account_id]
}

# Bucket names are global, so without source_account a same-named bucket in
# another account could invoke the function.
run "lambda_permissions_are_scoped_to_bucket_and_account" {
  command = plan

  variables {
    enable_auto_tagging    = true
    auto_tagging_s3_bucket = "test-artifacts"
    auto_tagging_s3_key    = "auto-tagging/auto-tagging.zip"
  }

  assert {
    condition = (
      aws_lambda_permission.oxbow_from_s3.source_arn == "arn:aws:s3:::scribdinc-data-lake-test" &&
      aws_lambda_permission.oxbow_from_s3.source_account == "123456789012"
    )
    error_message = "The oxbow invoke permission needs both source_arn and source_account"
  }

  assert {
    condition     = one(aws_lambda_permission.auto_tagging).source_account == "123456789012"
    error_message = "The auto-tagging invoke permission needs source_account"
  }
}

# The deny on queues with no cross-service publisher must not catch AWS itself,
# or an operator draining a DLQ through SQS redrive is locked out.
run "same_account_deny_exempts_aws_services" {
  command = plan

  assert {
    condition = anytrue([
      for c in local.same_account_only_statements["deny_outside_account"].condition :
      c.variable == "aws:PrincipalIsAWSService" && c.values == ["false"]
    ])
    error_message = "The deny must exempt AWS services acting on our behalf"
  }

  assert {
    condition = anytrue([
      for c in local.same_account_only_statements["deny_outside_account"].condition :
      c.variable == "aws:PrincipalAccount" && c.test == "StringNotEquals"
    ])
    error_message = "The deny must key off the calling account"
  }
}

# delta-rs documents exactly these actions for the DynamoDB logstore. Table
# creation is not among them: this module creates the lock table, and the
# logstore table is a pre-existing input.
run "dynamodb_grant_matches_the_documented_delta_rs_set" {
  command = plan

  assert {
    condition = toset(local.expected_dynamodb_actions) == toset([
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ])
    error_message = "The DynamoDB grant drifted from the documented delta-rs requirement"
  }

  assert {
    condition     = !contains(local.expected_dynamodb_actions, "dynamodb:CreateTable")
    error_message = "Neither table is created by the lambda, so CreateTable must not be granted"
  }

  assert {
    condition = alltrue([
      for a in local.expected_dynamodb_actions : !endswith(a, ":*")
    ])
    error_message = "No wildcard DynamoDB actions"
  }
}

# The stage configs default to all-empty strings, so enabling a stage without
# filling one in used to fail partway through an apply with provider errors
# naming neither the stage nor the field.
run "enabling_glue_create_without_its_config_is_rejected" {
  command = plan

  variables {
    enable_glue_create = true
  }

  expect_failures = [var.glue_create_config]
}

run "enabling_glue_sync_without_its_config_is_rejected" {
  command = plan

  variables {
    enable_glue_sync = true
  }

  expect_failures = [var.glue_sync_config]
}

run "enabling_auto_tagging_without_a_package_is_rejected" {
  command = plan

  variables {
    enable_auto_tagging = true
  }

  expect_failures = [var.auto_tagging_s3_key]
}

run "enabling_group_events_without_a_package_is_rejected" {
  command = plan

  variables {
    enable_group_events     = true
    events_lambda_s3_bucket = ""
  }

  expect_failures = [var.events_lambda_s3_key]
}

run "enabling_the_glue_catalog_table_without_its_config_is_rejected" {
  command = plan

  variables {
    enable_aws_glue_catalog_table = true
  }

  expect_failures = [var.glue_location_uri]
}

# S3 validates bucket names at plan, but only after the name is built; an
# over-long Athena results bucket is caught here instead.
run "over_length_athena_bucket_name_is_rejected" {
  command = plan

  variables {
    enable_glue_create = true
    glue_create_config = {
      athena_workgroup_name         = "test-glue-create"
      athena_data_source            = "AwsDataCatalog"
      athena_bucket_name            = "test-glue-create-athena-results-bucket-with-a-name-that-runs-past-sixty-three"
      lambda_s3_key                 = "glue-create/glue-create.zip"
      lambda_s3_bucket              = "test-artifacts"
      lambda_function_name          = "test-glue-create"
      path_regex                    = "^catalogs/"
      sns_topic_arn                 = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name                = "test-glue-create-queue"
      sqs_queue_name_dl             = "test-glue-create-queue-dl"
      iam_role_name                 = "test-glue-create-role"
      iam_policy_name               = "test-glue-create-policy"
      sns_subcription_filter_policy = ""
      filter_policy_scope           = ""
    }
  }

  expect_failures = [var.glue_create_config]
}

run "non_numeric_monitor_threshold_is_rejected" {
  command = plan

  variables {
    enabled_dead_letters_monitoring = true
    dl_critical                     = "two"
  }

  expect_failures = [var.dl_critical]
}
