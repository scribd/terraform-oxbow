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

  enable_group_events         = true
  events_lambda_function_name = "test-group-events"
  events_lambda_s3_bucket     = "test-artifacts"
  events_lambda_s3_key        = "group-events/group-events.zip"
  sqs_fifo_queue_name         = "test-oxbow-fifo"
  sqs_fifo_DL_queue_name      = "test-oxbow-fifo-dl"
  sqs_group_queue_name        = "test-group-events-queue"
  sqs_group_DL_queue_name     = "test-group-events-queue-dl"
}

run "grouping_swaps_the_standard_queue_for_the_fifo_pair" {
  command = plan

  assert {
    condition     = length(module.oxbow_queue) == 0
    error_message = "The standard oxbow queue must not exist when grouping is on"
  }

  assert {
    condition     = length(module.oxbow_fifo_queue) == 1 && length(module.group_events_queue) == 1
    error_message = "Grouping needs both the FIFO queue and the group-events queue"
  }

  assert {
    condition     = length(module.group_events_lambda) == 1
    error_message = "Group events lambda must exist when grouping is on"
  }
}

run "oxbow_consumes_the_fifo_queue_and_s3_feeds_the_group_queue" {
  command = plan

  assert {
    condition     = local.oxbow_source_queue_name == "test-oxbow-fifo.fifo"
    error_message = "Oxbow must read from the FIFO queue the grouping lambda feeds"
  }

  assert {
    condition     = local.ingest_queue_name == "test-group-events-queue"
    error_message = "Object-created events must land on the group-events queue"
  }

  assert {
    condition     = local.oxbow_source_queue_name != local.ingest_queue_name
    error_message = "Ingest and oxbow-source queues must be distinct under grouping"
  }
}

run "grouping_moves_sns_unwrapping_to_the_group_events_lambda" {
  command = plan

  variables {
    sns_topic_arn = "arn:aws:sns:us-east-2:123456789012:warehouse-events"
  }

  assert {
    condition     = !contains(keys(local.oxbow_environment), "UNWRAP_SNS_ENVELOPE")
    error_message = "Oxbow must not unwrap twice; the group-events lambda already did it"
  }
}

run "shared_role_carries_the_group_events_log_group" {
  command = plan

  assert {
    condition     = length(local.group_events_log_group_arns) == 2
    error_message = "The shared role needs the group-events log group and its streams"
  }

  assert {
    condition = alltrue([
      for arn in local.group_events_log_group_arns :
      strcontains(arn, "log-group:/aws/lambda/test-group-events")
    ])
    error_message = "Log permissions must be scoped to the group-events log group, not to *"
  }
}

run "fifo_names_carry_the_suffix_exactly_once" {
  command = plan

  variables {
    sqs_fifo_DL_queue_name = "test-oxbow-fifo-dl.fifo"
  }

  assert {
    condition     = local.fifo_dlq_name == "test-oxbow-fifo-dl.fifo"
    error_message = "A caller who already wrote .fifo must not get it appended twice"
  }
}

run "monitors_cover_both_grouping_dead_letter_queues" {
  command = plan

  variables {
    enabled_dead_letters_monitoring = true
    dl_critical                     = "1"
    dl_warning                      = "1"
  }

  assert {
    condition     = length(datadog_monitor.dead_letters) == 2
    error_message = "Grouping has two dead letter queues, so two monitors"
  }

  assert {
    condition = toset(local.dead_letter_queue_names) == toset([
      "test-oxbow-fifo-dl.fifo",
      "test-group-events-queue-dl",
    ])
    error_message = "Monitors must name the FIFO DLQ and the group-events DLQ, lowercased"
  }
}
