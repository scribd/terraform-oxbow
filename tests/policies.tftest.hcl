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

  # aws_iam_role and aws_iam_policy validate their JSON and ARNs client-side, so
  # the generated mock values have to parse. Policy content is therefore
  # asserted against the structured inputs, not against rendered JSON.
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

################################################################################
# Input validation
################################################################################

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

run "non_numeric_account_id_is_rejected" {
  command = plan
  variables {
    warehouse_bucket_account_id = "not-an-account"
  }
  expect_failures = [var.warehouse_bucket_account_id]
}

run "invalid_filter_policy_scope_is_rejected" {
  command = plan
  variables {
    glue_sync = {
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "glue-sync/glue-sync.zip"
      lambda_function_name = "test-glue-sync"
      sns_topic_arn        = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name       = "test-glue-sync-queue"
      sqs_queue_name_dl    = "test-glue-sync-queue-dl"
      iam_role_name        = "test-glue-sync-role"
      iam_policy_name      = "test-glue-sync-policy"
      filter_policy_scope  = ""
    }
  }
  expect_failures = [var.glue_sync]
}

################################################################################
# Name limits -- enforced by AWS at apply, not at plan
################################################################################

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
    lambda_function_name = "test-oxbow-function-name-just-under-the-limit-abcdef"
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
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

run "over_length_athena_bucket_name_is_rejected" {
  command = plan
  variables {
    glue_create = {
      athena_workgroup_name = "test-glue-create"
      athena_data_source    = "AwsDataCatalog"
      athena_bucket_name    = "test-glue-create-athena-results-bucket-with-a-name-past-sixty-three"
      lambda_s3_bucket      = "test-artifacts"
      lambda_s3_key         = "glue-create/glue-create.zip"
      lambda_function_name  = "test-glue-create"
      sns_topic_arn         = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name        = "test-glue-create-queue"
      sqs_queue_name_dl     = "test-glue-create-queue-dl"
      iam_role_name         = "test-glue-create-role"
      iam_policy_name       = "test-glue-create-policy"
    }
  }
  expect_failures = [var.glue_create]
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

################################################################################
# Policy defects found while auditing the rewrite
################################################################################

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

# Bucket names are global, so without source_account a same-named bucket in
# another account could invoke the function.
run "lambda_permissions_are_scoped_to_bucket_and_account" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
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
}

run "no_identity_policy_action_uses_a_wildcard" {
  command = plan

  assert {
    condition = alltrue([
      for a in concat(local.expected_dynamodb_actions, local.sqs_consumer_actions) :
      !endswith(a, ":*")
    ])
    error_message = "Identity-policy actions must be enumerated, never service:*"
  }

  assert {
    condition     = !contains(local.sqs_consumer_actions, "sqs:SendMessage")
    error_message = "A queue consumer has no business sending; the FIFO producer grant is separate"
  }
}

################################################################################
# SNS subscription filters
#
# glue_create and glue_sync already had a filter policy; those fields were only
# renamed to match the provider attribute. The oxbow ingest subscription and the
# auto-tagging subscription previously had none and took the whole topic.
################################################################################

run "ingest_subscription_filter_reaches_the_subscription" {
  command = plan

  variables {
    sns_delivery = {
      topic_arn           = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      filter_policy       = "{\"prefix\":[\"catalogs/bronze_monolith/\"]}"
      filter_policy_scope = "MessageBody"
    }
  }

  assert {
    condition     = one(aws_sns_topic_subscription.oxbow).filter_policy == "{\"prefix\":[\"catalogs/bronze_monolith/\"]}"
    error_message = "The ingest subscription must carry the configured filter policy"
  }
}

run "ingest_subscription_is_unfiltered_when_no_policy_is_given" {
  command = plan

  variables {
    sns_delivery = { topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events" }
  }

  assert {
    condition     = one(aws_sns_topic_subscription.oxbow).filter_policy == null
    error_message = "Omitting the filter must subscribe to the whole topic, not send an empty policy"
  }
}

# Auto tagging shares the topic but is a separate subscription, so it can take a
# narrower slice than oxbow.
run "auto_tagging_filter_is_independent_of_the_ingest_filter" {
  command = plan

  variables {
    sns_delivery = {
      topic_arn     = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      filter_policy = "{\"prefix\":[\"catalogs/\"]}"
    }
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
      filter_policy    = "{\"prefix\":[\"catalogs/bronze_monolith/\"]}"
    }
  }

  assert {
    condition = (
      one(aws_sns_topic_subscription.auto_tagging).filter_policy == "{\"prefix\":[\"catalogs/bronze_monolith/\"]}" &&
      one(aws_sns_topic_subscription.oxbow).filter_policy == "{\"prefix\":[\"catalogs/\"]}"
    )
    error_message = "Each subscription must carry its own filter, not a shared one"
  }
}

run "glue_stage_filters_survive_the_field_rename" {
  command = plan

  variables {
    glue_sync = {
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "glue-sync/glue-sync.zip"
      lambda_function_name = "test-glue-sync"
      sns_topic_arn        = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name       = "test-glue-sync-queue"
      sqs_queue_name_dl    = "test-glue-sync-queue-dl"
      iam_role_name        = "test-glue-sync-role"
      iam_policy_name      = "test-glue-sync-policy"
      filter_policy        = "{\"table\":[\"accounts\"]}"
      filter_policy_scope  = "MessageBody"
    }
  }

  assert {
    condition     = one(aws_sns_topic_subscription.glue_sync).filter_policy == "{\"table\":[\"accounts\"]}"
    error_message = "The renamed field must still reach the subscription"
  }
}

run "malformed_filter_policy_json_is_rejected" {
  command = plan

  variables {
    sns_delivery = {
      topic_arn     = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      filter_policy = "{not json"
    }
  }

  expect_failures = [var.sns_delivery]
}

run "unknown_filter_policy_scope_is_rejected" {
  command = plan

  variables {
    sns_delivery = {
      topic_arn           = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      filter_policy       = "{\"prefix\":[\"catalogs/\"]}"
      filter_policy_scope = "MessageHeaders"
    }
  }

  expect_failures = [var.sns_delivery]
}

# A scope with no policy silently filters nothing, which looks like a working
# filter until you notice every message arriving.
run "filter_policy_scope_without_a_policy_is_rejected" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket    = "test-artifacts"
      lambda_s3_key       = "auto-tagging/auto-tagging.zip"
      filter_policy_scope = "MessageBody"
    }
  }

  expect_failures = [var.auto_tagging]
}

################################################################################
# Publisher gating per queue
################################################################################

# The bucket notification this module writes targets the ingest queue only, so
# the auto-tagging queue was carrying an S3 grant nothing exercised.
run "auto_tagging_queue_has_no_unexercised_s3_grant" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
  }

  assert {
    condition     = length(keys(local.auto_tagging_queue_policy_statements)) == 0
    error_message = "Nothing publishes to the auto-tagging queue here, so it needs no resource policy"
  }

  assert {
    condition     = contains(keys(local.ingest_queue_policy_statements), "s3_send")
    error_message = "The ingest queue is the one the notification targets"
  }
}

run "auto_tagging_queue_admits_s3_when_the_caller_wires_it" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket  = "test-artifacts"
      lambda_s3_key     = "auto-tagging/auto-tagging.zip"
      s3_notifies_queue = true
    }
  }

  assert {
    condition     = keys(local.auto_tagging_queue_policy_statements) == ["s3_send"]
    error_message = "Opting in must grant S3 on the auto-tagging queue"
  }
}

################################################################################
# Name limits, continued
################################################################################

# The guard once capped IAM policy names at 64, the *role* limit, and rejected
# legal plans. IAM permits 128, and the provider validates it at plan anyway.
# https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html
run "iam_policy_name_of_100_chars_is_accepted" {
  command = plan

  variables {
    lambda_permissions_policy_name = "test-oxbow-policy-name-that-is-one-hundred-characters-long-which-iam-permits-for-policies-aaaaaaaaaa"
  }

  assert {
    condition     = length(var.lambda_permissions_policy_name) == 100
    error_message = "This case is only meaningful above the 64-char role limit"
  }

  assert {
    condition     = length(local.over_limit_names) == 0
    error_message = "A 100-character IAM policy name is legal and must not be rejected"
  }
}

################################################################################
# Delivery shapes
#
# The ingest queue can be fed by an S3 bucket notification, by an SNS topic
# subscription, or by both. This module owns neither, so each publisher is
# declared explicitly; inferring one from the other silently dropped events.
################################################################################

run "bucket_notification_only" {
  command = plan

  assert {
    condition     = keys(local.ingest_queue_policy_statements) == ["s3_send"]
    error_message = "An SQS-notification deployment must admit S3 and nothing else"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.oxbow) == 0
    error_message = "No topic means no subscription"
  }

  assert {
    condition     = !contains(keys(local.oxbow_environment), "UNWRAP_SNS_ENVELOPE")
    error_message = "Raw S3 events carry no SNS envelope to unwrap"
  }
}

run "sns_topic_only" {
  command = plan

  variables {
    sns_delivery             = { topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events" }
    s3_notifies_ingest_queue = false
  }

  assert {
    condition     = keys(local.ingest_queue_policy_statements) == ["sns_send"]
    error_message = "A topic-only deployment must not carry an S3 grant nothing uses"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.oxbow) == 1
    error_message = "The ingest queue must be subscribed to the topic"
  }

  assert {
    condition     = local.oxbow_environment["UNWRAP_SNS_ENVELOPE"] == true
    error_message = "Oxbow must unwrap the SNS envelope when fed from a topic"
  }
}

run "both_publishers_at_once" {
  command = plan

  variables {
    sns_delivery = { topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events" }
  }

  assert {
    condition     = toset(keys(local.ingest_queue_policy_statements)) == toset(["s3_send", "sns_send"])
    error_message = "A queue fed by both a bucket notification and a topic must admit both"
  }

  assert {
    condition     = length(aws_sns_topic_subscription.oxbow) == 1
    error_message = "The topic subscription is still created"
  }
}

run "s3_grant_is_scoped_identically_on_both_shapes" {
  command = plan

  variables {
    sns_delivery = { topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events" }
  }

  assert {
    condition = alltrue([
      for c in local.ingest_queue_policy_statements["s3_send"].condition :
      contains(["aws:SourceArn", "aws:SourceAccount"], c.variable)
    ])
    error_message = "The S3 grant keeps its bucket and account conditions regardless of the other publisher"
  }

  assert {
    condition     = local.ingest_queue_policy_statements["sns_send"].condition[0].values == ["arn:aws:sns:us-east-2:123456789012:warehouse-events"]
    error_message = "The SNS grant stays scoped to the configured topic"
  }
}
