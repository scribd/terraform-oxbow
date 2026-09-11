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

run "trailing_slash_on_s3_path_is_rejected" {
  command = plan

  variables {
    s3_path = "catalogs/bronze_monolith/"
  }

  expect_failures = [var.s3_path]
}

run "bucket_arn_must_be_an_arn" {
  command = plan

  variables {
    warehouse_bucket_arn = "scribdinc-data-lake-test"
  }

  expect_failures = [var.warehouse_bucket_arn]
}

run "unknown_architecture_is_rejected" {
  command = plan

  variables {
    architectures = ["arm64", "x86_64"]
  }

  expect_failures = [var.architectures]
}

# A Lambda name over 64 characters is accepted at plan and fails mid-apply,
# after earlier resources have already changed. The guard turns that into a
# plan-time failure.
run "over_length_lambda_name_fails_at_plan" {
  command = plan

  variables {
    lambda_function_name = "test-oxbow-with-a-name-that-is-far-too-long-to-be-a-lambda-function-name"
  }

  expect_failures = [terraform_data.name_length_guard]
}

run "over_length_derived_auto_tagging_name_fails_at_plan" {
  command = plan

  variables {
    # 52 chars; the "-auto_tagging" suffix pushes the derived name past 64.
    lambda_function_name   = "test-oxbow-function-name-just-under-the-limit-abcdef"
    enable_auto_tagging    = true
    auto_tagging_s3_bucket = "test-artifacts"
    auto_tagging_s3_key    = "auto-tagging/auto-tagging.zip"
  }

  expect_failures = [terraform_data.name_length_guard]
}

run "over_length_sqs_name_fails_at_plan" {
  command = plan

  variables {
    sqs_queue_name = "test-oxbow-queue-with-a-name-that-runs-well-past-the-eighty-character-limit-for-sqs"
  }

  expect_failures = [terraform_data.name_length_guard]
}

run "names_at_the_limit_are_accepted" {
  command = plan

  variables {
    # Exactly 64 characters.
    lambda_function_name = "test-oxbow-function-name-that-is-exactly-sixty-four-chars-long-a"
  }

  assert {
    condition     = length(var.lambda_function_name) == 64
    error_message = "This case is only meaningful at exactly the limit"
  }

  assert {
    condition     = length(local.over_limit_names) == 0
    error_message = "A name exactly at the limit must pass"
  }
}

run "monitoring_without_a_threshold_is_rejected" {
  command = plan

  variables {
    enabled_dead_letters_monitoring = true
  }

  expect_failures = [datadog_monitor.dead_letters]
}
