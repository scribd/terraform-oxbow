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

run "auto_tagging_derives_its_names_from_the_oxbow_names" {
  command = plan

  variables {
    enable_auto_tagging    = true
    auto_tagging_s3_bucket = "test-artifacts"
    auto_tagging_s3_key    = "auto-tagging/auto-tagging.zip"
  }

  assert {
    condition     = length(module.auto_tagging_lambda) == 1 && length(module.auto_tagging_queue) == 1
    error_message = "Auto tagging creates its own lambda and queue"
  }

  assert {
    condition     = local.auto_tagging_function == "test-oxbow-auto_tagging"
    error_message = "Auto tagging function name is derived from lambda_function_name"
  }

  assert {
    condition     = local.auto_tagging_queue_name == "test-oxbow-queue-auto_tagging"
    error_message = "Auto tagging queue name is derived from sqs_queue_name"
  }

  assert {
    condition     = one(aws_iam_policy.auto_tagging).name == "test-oxbow-policy-auto_tagging"
    error_message = "Auto tagging gets its own policy, not the oxbow one"
  }

  assert {
    condition     = one(aws_lambda_permission.auto_tagging).source_arn == "arn:aws:s3:::scribdinc-data-lake-test"
    error_message = "Only the warehouse bucket may invoke the auto tagging lambda"
  }
}

run "glue_create_wires_athena_workgroup_queue_and_subscription" {
  command = plan

  variables {
    enable_glue_create = true
    glue_create_config = {
      athena_workgroup_name         = "test-glue-create"
      athena_data_source            = "AwsDataCatalog"
      athena_bucket_name            = "test-glue-create-athena"
      lambda_s3_key                 = "glue-create/glue-create.zip"
      lambda_s3_bucket              = "test-artifacts"
      lambda_function_name          = "test-glue-create"
      path_regex                    = "^catalogs/(?<database>[^/]+)/(?<table>[^/]+)"
      sns_topic_arn                 = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name                = "test-glue-create-queue"
      sqs_queue_name_dl             = "test-glue-create-queue-dl"
      iam_role_name                 = "test-glue-create-role"
      iam_policy_name               = "test-glue-create-policy"
      sns_subcription_filter_policy = ""
      filter_policy_scope           = ""
    }
  }

  assert {
    condition     = length(module.glue_create_lambda) == 1 && length(module.glue_create_queue) == 1
    error_message = "glue-create creates a lambda and a queue"
  }

  assert {
    condition     = length(module.glue_create_athena_workgroup_bucket) == 1 && length(aws_athena_workgroup.glue_create) == 1
    error_message = "glue-create needs its own Athena workgroup and results bucket"
  }

  assert {
    condition     = one(aws_sns_topic_subscription.glue_create).topic_arn == "arn:aws:sns:us-east-2:123456789012:warehouse-events"
    error_message = "glue-create subscribes its queue to its configured topic"
  }

  assert {
    condition     = length(module.glue_sync_lambda) == 0
    error_message = "Enabling glue-create must not drag in glue-sync"
  }
}

run "glue_sync_is_independent_of_glue_create" {
  command = plan

  variables {
    enable_glue_sync = true
    glue_sync_config = {
      lambda_s3_key                 = "glue-sync/glue-sync.zip"
      lambda_s3_bucket              = "test-artifacts"
      lambda_function_name          = "test-glue-sync"
      path_regex                    = "^catalogs/(?<database>[^/]+)/(?<table>[^/]+)"
      sns_topic_arn                 = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name                = "test-glue-sync-queue"
      sqs_queue_name_dl             = "test-glue-sync-queue-dl"
      iam_role_name                 = "test-glue-sync-role"
      iam_policy_name               = "test-glue-sync-policy"
      sns_subcription_filter_policy = ""
      filter_policy_scope           = ""
    }
  }

  assert {
    condition     = length(module.glue_sync_lambda) == 1 && length(module.glue_sync_queue) == 1
    error_message = "glue-sync creates a lambda and a queue"
  }

  assert {
    condition     = length(aws_athena_workgroup.glue_create) == 0
    error_message = "glue-sync must not create an Athena workgroup"
  }
}

run "glue_catalog_table_is_parquet_backed" {
  command = plan

  variables {
    enable_aws_glue_catalog_table = true
    glue_database_name            = "bronze_monolith"
    glue_table_name               = "test_table"
    glue_location_uri             = "s3://scribdinc-data-lake-test/catalogs/bronze_monolith/test_table"
    parquet_schema = [
      { name = "id", type = "bigint" },
      { name = "created_at", type = "timestamp" },
    ]
  }

  assert {
    condition     = one(aws_glue_catalog_table.oxbow).parameters["classification"] == "parquet"
    error_message = "The catalog table must be classified as parquet"
  }

  assert {
    condition     = length(one(one(aws_glue_catalog_table.oxbow).storage_descriptor).columns) == 2
    error_message = "Every column in parquet_schema must reach the storage descriptor"
  }
}

run "every_dead_letter_queue_gets_a_monitor" {
  command = plan

  variables {
    enable_auto_tagging    = true
    auto_tagging_s3_bucket = "test-artifacts"
    auto_tagging_s3_key    = "auto-tagging/auto-tagging.zip"

    enable_glue_sync = true
    glue_sync_config = {
      lambda_s3_key                 = "glue-sync/glue-sync.zip"
      lambda_s3_bucket              = "test-artifacts"
      lambda_function_name          = "test-glue-sync"
      path_regex                    = "^catalogs/"
      sns_topic_arn                 = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name                = "test-glue-sync-queue"
      sqs_queue_name_dl             = "test-glue-sync-queue-dl"
      iam_role_name                 = "test-glue-sync-role"
      iam_policy_name               = "test-glue-sync-policy"
      sns_subcription_filter_policy = ""
      filter_policy_scope           = ""
    }

    enabled_dead_letters_monitoring = true
    dl_critical                     = "2"
    dl_warning                      = "1"
    monitoring_query_conditions     = "env:test"
  }

  assert {
    condition = toset(local.dead_letter_queue_names) == toset([
      "test-oxbow-queue-dl",
      "test-oxbow-queue-auto_tagging-dl",
      "test-glue-sync-queue-dl",
    ])
    error_message = "Each enabled stage contributes exactly its own dead letter queue"
  }

  assert {
    condition     = length(datadog_monitor.dead_letters) == 3
    error_message = "One monitor per dead letter queue"
  }

  assert {
    condition = alltrue([
      for m in values(datadog_monitor.dead_letters) :
      strcontains(m.query, ", env:test}")
    ])
    error_message = "monitoring_query_conditions must be appended to the monitor scope"
  }
}
