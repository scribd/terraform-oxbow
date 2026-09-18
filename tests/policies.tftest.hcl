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
  bucket_arn = "arn:aws:s3:::example-data-lake-test"
  s3_path    = "catalogs/bronze_monolith"


  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"
  aws_s3_locking_provider        = "dynamodb"

  oxbow = {
    lambda_function_name = "test-oxbow"
    lambda_s3_bucket     = "test-artifacts"
    lambda_s3_key        = "oxbow/oxbow-lambda.zip"
    role_name            = "test-oxbow-role"
    policy_name          = "test-oxbow-policy"
    queue_name           = "test-oxbow-queue"
    dl_queue_name        = "test-oxbow-queue-dl"
  }

  dynamodb_table_name          = "test-oxbow-lock"
  logstore_dynamodb_table_name = "test-delta-logstore"

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
    bucket_arn = "example-data-lake-test"
  }
  expect_failures = [var.bucket_arn]
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
    bucket_account_id = "not-an-account"
  }
  expect_failures = [var.bucket_account_id]
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
    oxbow = {
      lambda_function_name = "test-oxbow-with-a-name-that-is-far-too-long-to-be-a-lambda-function-name"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "oxbow/oxbow-lambda.zip"
      role_name            = "test-oxbow-role"
      policy_name          = "test-oxbow-policy"
      queue_name           = "test-oxbow-queue"
      dl_queue_name        = "test-oxbow-queue-dl"
    }
  }
  expect_failures = [terraform_data.config_guard]
}

run "over_length_derived_auto_tagging_name_fails_at_plan" {
  command = plan
  variables {
    # 52 chars; the "-auto_tagging" suffix pushes the derived name past 64.
    oxbow = {
      lambda_function_name = "test-oxbow-function-name-just-under-the-limit-abcdef"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "oxbow/oxbow-lambda.zip"
      role_name            = "test-oxbow-role"
      policy_name          = "test-oxbow-policy"
      queue_name           = "test-oxbow-queue"
      dl_queue_name        = "test-oxbow-queue-dl"
    }
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
  }
  expect_failures = [terraform_data.config_guard]
}

run "over_length_sqs_name_fails_at_plan" {
  command = plan
  variables {
    oxbow = {
      lambda_function_name = "test-oxbow"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "oxbow/oxbow-lambda.zip"
      role_name            = "test-oxbow-role"
      policy_name          = "test-oxbow-policy"
      queue_name           = "test-oxbow-queue-with-a-name-that-runs-well-past-the-eighty-character-limit-for-sqs"
      dl_queue_name        = "test-oxbow-queue-dl"
    }
  }
  expect_failures = [terraform_data.config_guard]
}

# The guard once measured dl_queue_name before checking it for null, so this
# configuration died on length(null) in locals.tf and the precondition's own
# message was never reached.
run "dl_queue_name_is_required_when_grouping_is_off" {
  command = plan
  variables {
    oxbow = {
      lambda_function_name = "test-oxbow"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "oxbow/oxbow-lambda.zip"
      role_name            = "test-oxbow-role"
      policy_name          = "test-oxbow-policy"
      queue_name           = "test-oxbow-queue"
    }
  }
  expect_failures = [terraform_data.config_guard]
}

run "empty_s3_path_is_rejected" {
  command = plan
  variables {
    s3_path = ""
  }
  expect_failures = [var.s3_path]
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
    oxbow = {
      lambda_function_name = "test-oxbow-function-name-that-is-exactly-sixty-four-chars-long-a"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "oxbow/oxbow-lambda.zip"
      role_name            = "test-oxbow-role"
      policy_name          = "test-oxbow-policy"
      queue_name           = "test-oxbow-queue"
      dl_queue_name        = "test-oxbow-queue-dl"
    }
  }

  assert {
    condition     = length(var.oxbow.lambda_function_name) == 64
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
# event from a bucket owned by another account.
run "cross_account_bucket_is_supported" {
  command = plan

  variables {
    bucket_account_id = "210987654321"
  }

  assert {
    condition = anytrue([
      for c in local.ingest_queue_policy_statements["s3_send"].condition :
      c.variable == "aws:SourceAccount" && c.values == ["210987654321"]
    ])
    error_message = "SourceAccount must name the bucket owner, not the deploying account"
  }
}

run "bucket_account_defaults_to_this_account" {
  command = plan

  assert {
    condition     = local.bucket_account_id == "123456789012"
    error_message = "Omitting the variable must keep the current account"
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
      c.variable == "aws:PrincipalAccount" && c.test == "StringNotEqualsIfExists"
    ])
    error_message = "The deny must key off the calling account"
  }

  # Conditions are ANDed, so a plain Bool on a key the request does not carry
  # evaluates false and takes the whole deny with it. An unsigned request
  # carries neither key.
  assert {
    condition = alltrue([
      for c in local.same_account_only_statements["deny_outside_account"].condition :
      endswith(c.test, "IfExists")
    ])
    error_message = "Every condition on a deny must use an IfExists form or the deny goes inert on an absent key"
  }
}

# delta-rs documents exactly these actions for the DynamoDB logstore. Table
# creation is not among them: both tables are pre-existing inputs this module
# is only pointed at.
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

# Asserted against the rendered documents, not the action locals: the earlier
# version of this swept five locals and so could not see the statements written
# inline in oxbow.tf, autotagging.tf and glue_create.tf, where "s3:*" would
# have passed the whole suite.
run "no_identity_policy_statement_uses_a_wildcard" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }

    glue_create = {
      athena_workgroup_name = "test-glue-create"
      athena_data_source    = "AwsDataCatalog"
      athena_bucket_name    = "test-glue-create-athena"
      lambda_s3_bucket      = "test-artifacts"
      lambda_s3_key         = "glue-create/glue-create.zip"
      lambda_function_name  = "test-glue-create"
      sns_topic_arn         = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name        = "test-glue-create-queue"
      sqs_queue_name_dl     = "test-glue-create-queue-dl"
      iam_role_name         = "test-glue-create-role"
      iam_policy_name       = "test-glue-create-policy"
    }

    glue_sync = {
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "glue-sync/glue-sync.zip"
      lambda_function_name = "test-glue-sync"
      sns_topic_arn        = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
      sqs_queue_name       = "test-glue-sync-queue"
      sqs_queue_name_dl    = "test-glue-sync-queue-dl"
      iam_role_name        = "test-glue-sync-role"
      iam_policy_name      = "test-glue-sync-policy"
    }
  }

  assert {
    condition = alltrue(flatten([
      for doc in concat(
        data.aws_iam_policy_document.oxbow_lambda,
        data.aws_iam_policy_document.auto_tagging,
        data.aws_iam_policy_document.glue_create,
        data.aws_iam_policy_document.glue_sync,
      ) : [for st in doc.statement : [for a in st.actions : !strcontains(a, "*")]]
    ]))
    error_message = "Identity-policy actions must be enumerated -- no *, service:* or partial glob"
  }

  assert {
    condition = alltrue(flatten([
      for doc in concat(
        data.aws_iam_policy_document.oxbow_lambda,
        data.aws_iam_policy_document.auto_tagging,
        data.aws_iam_policy_document.glue_create,
        data.aws_iam_policy_document.glue_sync,
      ) : [for st in doc.statement : [for r in st.resources : r != "*"]]
    ]))
    error_message = "No identity-policy statement may name Resource \"*\""
  }

  # Proves the sweep is looking at something: four documents, none empty.
  assert {
    condition = alltrue([
      for doc in concat(
        data.aws_iam_policy_document.oxbow_lambda,
        data.aws_iam_policy_document.auto_tagging,
        data.aws_iam_policy_document.glue_create,
        data.aws_iam_policy_document.glue_sync,
      ) : length(doc.statement) > 0
    ]) && length(data.aws_iam_policy_document.oxbow_lambda[0].statement) == 4
    error_message = "The sweep must see every statement of all four policy documents"
  }

  assert {
    condition     = !contains(local.sqs_consumer_actions, "sqs:SendMessage")
    error_message = "A queue consumer has no business sending; the FIFO producer grant is separate"
  }
}

# The lambda module grants CreateLogGroup exactly when OpenTofu manages the
# group, i.e. when it has already created it -- so it is dead either way, and
# the hand-rolled statement for the shared role must not reintroduce it.
run "no_role_can_create_a_log_group" {
  command = plan

  assert {
    condition     = !contains(local.lambda_logs_actions, "logs:CreateLogGroup")
    error_message = "The group exists under both settings, so no role needs logs:CreateLogGroup"
  }

  assert {
    condition     = toset(local.lambda_logs_actions) == toset(["logs:CreateLogStream", "logs:PutLogEvents"])
    error_message = "The logs grant is exactly stream creation and writing"
  }
}

# The glue queues' policies were written inline in their module calls, where no
# assertion could reach them.
run "no_glue_queue_policy_allows_a_wildcard_principal" {
  command = plan

  variables {
    glue_create = {
      athena_workgroup_name = "test-glue-create"
      athena_data_source    = "AwsDataCatalog"
      athena_bucket_name    = "test-glue-create-athena"
      lambda_s3_bucket      = "test-artifacts"
      lambda_s3_key         = "glue-create/glue-create.zip"
      lambda_function_name  = "test-glue-create"
      sns_topic_arn         = "arn:aws:sns:us-east-2:123456789012:glue-create-events"
      sqs_queue_name        = "test-glue-create-queue"
      sqs_queue_name_dl     = "test-glue-create-queue-dl"
      iam_role_name         = "test-glue-create-role"
      iam_policy_name       = "test-glue-create-policy"
    }

    glue_sync = {
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "glue-sync/glue-sync.zip"
      lambda_function_name = "test-glue-sync"
      sns_topic_arn        = "arn:aws:sns:us-east-2:123456789012:glue-sync-events"
      sqs_queue_name       = "test-glue-sync-queue"
      sqs_queue_name_dl    = "test-glue-sync-queue-dl"
      iam_role_name        = "test-glue-sync-role"
      iam_policy_name      = "test-glue-sync-policy"
    }
  }

  assert {
    condition     = length(local.glue_queue_policy_statements) == 2
    error_message = "Both glue stages must contribute a queue policy for this sweep to mean anything"
  }

  assert {
    condition = alltrue(flatten([
      for stage in local.glue_queue_policy_statements : [
        for st in stage : [
          for p in st.principals : !(st.effect == "Allow" && contains(p.identifiers, "*"))
        ]
      ]
    ]))
    error_message = "A glue queue policy names a wildcard principal on an Allow"
  }

  assert {
    condition = alltrue(flatten([
      for stage in local.glue_queue_policy_statements : [
        for st in stage : [for a in st.actions : !endswith(a, ":*")]
      ]
    ]))
    error_message = "A glue queue policy grants a wildcard action"
  }

  # Each stage subscribes to its own topic, so a shared statement would admit
  # the other stage's topic to both queues.
  assert {
    condition = (
      local.glue_queue_policy_statements["glue_create"]["sns_send"].condition[0].values == ["arn:aws:sns:us-east-2:123456789012:glue-create-events"] &&
      local.glue_queue_policy_statements["glue_sync"]["sns_send"].condition[0].values == ["arn:aws:sns:us-east-2:123456789012:glue-sync-events"]
    )
    error_message = "Each glue queue policy must be scoped to that stage's own topic"
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
    condition     = length(keys(local.auto_tagging_queue_publishers)) == 0
    error_message = "Nothing publishes to the auto-tagging queue here, so it gets no publisher grant"
  }

  # It still needs a policy with at least one statement: a zero-statement
  # document omits the Statement key entirely and SQS rejects it.
  assert {
    condition     = keys(local.auto_tagging_queue_policy_statements) == ["deny_outside_account"]
    error_message = "A publisher-less queue must fall back to the same-account deny, not an empty policy"
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
    condition     = keys(local.auto_tagging_queue_publishers) == ["s3_send"]
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
    oxbow = {
      lambda_function_name = "test-oxbow"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "oxbow/oxbow-lambda.zip"
      role_name            = "test-oxbow-role"
      policy_name          = "test-oxbow-policy-name-that-is-one-hundred-characters-long-which-iam-permits-for-policies-aaaaaaaaaa"
      queue_name           = "test-oxbow-queue"
      dl_queue_name        = "test-oxbow-queue-dl"
    }
  }

  assert {
    condition     = length(var.oxbow.policy_name) == 100
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
    condition     = local.oxbow_environment["UNWRAP_SNS_ENVELOPE"] == "true"
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

# A zero-statement aws_iam_policy_document renders as {"Version": "2012-10-17"}
# with no Statement key, which SetQueueAttributes rejects with
# MalformedPolicyDocument. Every queue this module gives a policy to must
# therefore end up with at least one statement.
run "no_queue_ever_gets_an_empty_policy" {
  command = plan

  variables {
    s3_notifies_ingest_queue = false
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
  }

  assert {
    condition     = length(local.ingest_queue_publishers) == 0 && length(local.auto_tagging_queue_publishers) == 0
    error_message = "This case is only meaningful when neither queue has a publisher"
  }

  assert {
    condition     = length(local.ingest_queue_policy_statements) > 0
    error_message = "The ingest queue policy would render without a Statement key"
  }

  assert {
    condition     = length(local.auto_tagging_queue_policy_statements) > 0
    error_message = "The auto-tagging queue policy would render without a Statement key"
  }
}

# The sqs module's dlq_message_retention_seconds defaults to null and only
# reaches 14 days by coalescing from the primary queue. It is passed explicitly
# so the DLQs do not silently fall back to the AWS 4-day default if that
# coalesce ever changes.
# Only the default is assertable here: the value reaches each DLQ through the
# sqs module, which exposes no retention output, so that wiring is verifiable
# on a real plan and nowhere else.
run "retention_defaults_to_the_sqs_maximum" {
  command = plan

  assert {
    condition     = var.message_retention_seconds == 1209600
    error_message = "The default must be 14 days, the SQS maximum, not the AWS 4-day fallback"
  }
}

run "retention_above_the_sqs_maximum_is_rejected" {
  command = plan
  variables {
    message_retention_seconds = 1209601
  }
  expect_failures = [var.message_retention_seconds]
}

run "retention_below_the_sqs_minimum_is_rejected" {
  command = plan
  variables {
    message_retention_seconds = 59
  }
  expect_failures = [var.message_retention_seconds]
}

# `Ok(_) => s3_from_sns(...)` in the auto-tag binary matches the variable's
# presence, not its value, so UNWRAP_SNS_ENVELOPE=false still unwraps an
# envelope that is not there: zero records, nothing tagged, no error, no DLQ.
run "auto_tagging_omits_the_unwrap_flag_without_a_topic" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket  = "test-artifacts"
      lambda_s3_key     = "auto-tagging/auto-tagging.zip"
      s3_notifies_queue = true
    }
  }

  assert {
    condition     = !contains(keys(local.auto_tagging_environment), "UNWRAP_SNS_ENVELOPE")
    error_message = "Fed straight from S3, the flag must be absent rather than false"
  }

  assert {
    condition     = local.auto_tagging_environment["RUST_LOG"] == "info"
    error_message = "The auto-tagging lambda needs RUST_LOG or it logs nothing"
  }
}

run "auto_tagging_sets_the_unwrap_flag_with_a_topic" {
  command = plan

  variables {
    sns_delivery = { topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events" }
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
  }

  assert {
    condition     = local.auto_tagging_environment["UNWRAP_SNS_ENVELOPE"] == "true"
    error_message = "Fed from a topic, the lambda must unwrap the envelope"
  }
}

# glue-sync calls get_table and update_table; glue-create adds get_database,
# create_database, and create_table indirectly through Athena's DDL. Everything
# else the old policies granted traced to no call either binary makes.
run "glue_grants_trace_to_calls_the_binaries_make" {
  command = plan

  assert {
    condition     = toset(local.glue_sync_actions) == toset(["glue:GetTable", "glue:UpdateTable"])
    error_message = "glue-sync only reads and updates existing tables"
  }

  assert {
    condition     = !contains(local.glue_sync_actions, "glue:CreateTable") && !contains(local.glue_sync_actions, "glue:CreateDatabase")
    error_message = "A read-and-update lambda must not be able to mint catalog objects"
  }

  assert {
    condition     = !contains(local.athena_actions, "athena:ListWorkGroups")
    error_message = "The workgroup comes from ATHENA_WORKGROUP; nothing lists them, and listing needs Resource \"*\""
  }

  assert {
    condition = alltrue([
      for a in ["athena:GetQueryResults", "athena:StopQueryExecution"] :
      !contains(local.athena_actions, a)
    ])
    error_message = "The DDL returns no results and is never cancelled"
  }
}
