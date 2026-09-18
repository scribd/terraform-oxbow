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
  bucket_arn = "arn:aws:s3:::scribdinc-data-lake-test"
  s3_path    = "catalogs/bronze_monolith"


  # Deliberately none of the oxbow-only inputs: the whole point of this file is
  # the configuration the README documents for a glue-only deployment. Setting
  # them here is what let locals interpolating them past the suite once before.
  rust_log_oxbow_debug_level = "info"
}

# oxbow = null turns the core stage off, so the module can deploy the auxiliary
# stages on their own against a bucket whose Delta tables something else
# writes.

run "everything_off_creates_nothing_but_still_plans" {
  command = plan

  assert {
    condition     = !anytrue(values(local.enabled))
    error_message = "With every config object null, no stage is enabled"
  }

  assert {
    condition     = local.lock_table_arn == null
    error_message = "No stage uses a lock table here, so its ARN must not be built from a null name"
  }

  assert {
    condition     = local.oxbow_environment == {}
    error_message = "The oxbow environment must not be built when the stage is off"
  }

  assert {
    condition = (
      length(module.oxbow_lambda) == 0 &&
      length(module.oxbow_queue) == 0 &&
      length(aws_iam_policy.oxbow_lambda) == 0
    )
    error_message = "The oxbow stage must create nothing when its object is null"
  }

  assert {
    condition     = local.ingest_queue_arn == null && local.oxbow_source_queue_arn == null
    error_message = "There is no ingest queue without the oxbow stage"
  }
}

run "auto_tagging_alone_needs_its_own_names" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
    }
  }

  expect_failures = [var.auto_tagging]
}

run "auto_tagging_alone_with_explicit_names" {
  command = plan

  variables {
    auto_tagging = {
      lambda_s3_bucket = "test-artifacts"
      lambda_s3_key    = "auto-tagging/auto-tagging.zip"
      function_name    = "test-autotag"
      role_name        = "test-autotag-role"
      policy_name      = "test-autotag-policy"
      queue_name       = "test-autotag-queue"
    }
  }

  assert {
    condition     = local.enabled.auto_tagging && !local.enabled.oxbow
    error_message = "Auto tagging must stand on its own"
  }

  assert {
    condition     = length(module.auto_tagging_lambda) == 1 && length(module.oxbow_lambda) == 0
    error_message = "Only the auto-tagging lambda is created"
  }

  assert {
    condition     = local.auto_tagging_function == "test-autotag" && local.auto_tagging_dlq_name == "test-autotag-queue-dl"
    error_message = "Explicit names are used verbatim; the DLQ still derives from the queue name"
  }
}

run "glue_stages_alone_need_no_oxbow" {
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
    }
  }

  assert {
    condition     = length(module.glue_sync_lambda) == 1 && length(module.oxbow_lambda) == 0
    error_message = "glue-sync has its own role and queue, so it needs no oxbow"
  }

  assert {
    condition     = toset(local.dead_letter_queue_names) == toset(["test-glue-sync-queue-dl"])
    error_message = "Only the enabled stage's DLQ is monitored; there is no oxbow DLQ"
  }
}

# group_events feeds a FIFO queue only oxbow consumes, and shares its role.
run "group_events_without_oxbow_is_rejected" {
  command = plan

  variables {
    group_events = {
      lambda_function_name = "test-group-events"
      lambda_s3_bucket     = "test-artifacts"
      lambda_s3_key        = "group-events/group-events.zip"
      queue_name           = "test-group-events-queue"
      dl_queue_name        = "test-group-events-queue-dl"
      fifo_queue_name      = "test-oxbow-fifo"
      fifo_dl_queue_name   = "test-oxbow-fifo-dl"
    }
  }

  expect_failures = [var.group_events]
}
