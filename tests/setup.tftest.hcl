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
  warehouse_bucket_arn = "arn:aws:s3:::scribdinc-data-lake-test"
  s3_path              = "catalogs/bronze_monolith"


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

run "minimal_deployment" {
  command = plan

  assert {
    condition     = module.oxbow_lambda[0].lambda_function_name == "test-oxbow"
    error_message = "Oxbow function name should come straight from lambda_function_name"
  }

  assert {
    condition     = !anytrue([for k, v in local.enabled : v if k != "oxbow"])
    error_message = "Every stage but oxbow must be off when its config variable is null"
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
    condition = (
      length(module.group_events_lambda) == 0 &&
      length(module.auto_tagging_lambda) == 0 &&
      length(module.glue_create_lambda) == 0 &&
      length(module.glue_sync_lambda) == 0
    )
    error_message = "No optional lambda may exist by default"
  }

  assert {
    condition = (
      length(aws_sns_topic_subscription.oxbow) == 0 &&
      length(datadog_monitor.dead_letters) == 0
    )
    error_message = "No optional resource may exist by default"
  }

  assert {
    condition     = local.lock_table_arn == "arn:aws:dynamodb:us-east-2:123456789012:table/test-oxbow-lock"
    error_message = "The lock table ARN must be derived from the name of the existing table"
  }
}

run "oxbow_environment_without_sns" {
  command = plan

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
    sns_delivery = { topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events" }
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

# The previous module granted sqs:SendMessage to Principal "*" on every dead
# letter queue under a ForAllValues condition on aws:SourceArn. AWS evaluates
# ForAllValues as true when the key is absent, and aws:SourceArn is absent on a
# direct SendMessage call, so those queues were writable by any AWS account.
run "no_queue_policy_allows_a_wildcard_principal" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in values(local.ingest_queue_policy_statements) : [
        for p in s.principals : !(s.effect == "Allow" && contains(p.identifiers, "*"))
      ]
    ]))
    error_message = "An Allow statement on an ingest queue names a wildcard principal"
  }

  assert {
    condition = alltrue([
      for s in values(local.same_account_only_statements) : s.effect == "Deny"
    ])
    error_message = "The shared queue policy must be a deny; a wildcard principal is only safe under Deny"
  }

  assert {
    condition = alltrue(flatten([
      for s in concat(values(local.same_account_only_statements), values(local.ingest_queue_policy_statements)) : [
        for c in s.condition : !startswith(c.test, "ForAllValues:")
      ]
    ]))
    error_message = "ForAllValues evaluates true when the condition key is absent; never use it to gate access"
  }
}

