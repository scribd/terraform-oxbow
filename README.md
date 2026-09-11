# terraform-oxbow

OpenTofu module for the oxbow pipeline: parquet objects landing in a warehouse
bucket are turned into Delta tables, with optional event grouping, object
auto-tagging, Glue catalog creation and sync, and Datadog dead-letter alerting.

The AWS primitives come from the published `terraform-aws-modules` lambda, sqs
and s3-bucket modules. Requires OpenTofu >= 1.12, the AWS provider >= 6.42 and
the Datadog provider >= 4.0.

Upgrading from a release before the module rewrite? Read [UPGRADING.md](UPGRADING.md)
first — it is a no-downtime upgrade, but it is not a no-op plan.

## Shape of the pipeline

```
                     enable_group_events = false
S3 (or SNS) ──► oxbow queue ──► oxbow lambda ──► Delta table
                     │
                     └──► DLQ ──► Datadog monitor

                     enable_group_events = true
S3 (or SNS) ──► group queue ──► group-events lambda ──► FIFO queue ──► oxbow lambda
                     │                                       │
                     └──► DLQ                                └──► DLQ
```

Every stage below the core is independently switchable, and each one that has a
queue gets a dead letter queue and, when `enabled_dead_letters_monitoring` is
on, a Datadog monitor.

| Toggle | Creates |
| --- | --- |
| `enable_group_events` | group-events lambda, its standard queue, the FIFO queue oxbow then reads |
| `enable_auto_tagging` | auto-tagging lambda, queue, own IAM role |
| `enable_glue_create` | glue-create lambda, queue, Athena workgroup and results bucket |
| `enable_glue_sync` | glue-sync lambda and queue |
| `enable_aws_glue_catalog_table` | a Glue catalog table over the parquet location |
| `enable_bucket_notification` | the warehouse bucket's notification configuration |
| `enabled_dead_letters_monitoring` | one Datadog monitor per dead letter queue |

## Usage

```hcl
module "oxbow" {
  source = "github.com/scribd/terraform-oxbow?ref=v2.0.0"

  warehouse_bucket_arn  = module.warehouse.s3_bucket_arn
  warehouse_bucket_name = module.warehouse.s3_bucket_id
  s3_path               = "catalogs/bronze_monolith"

  lambda_function_name           = "${var.env}-oxbow"
  lambda_s3_bucket               = var.artifacts_bucket
  lambda_s3_key                  = "oxbow/oxbow-lambda.zip"
  oxbow_lambda_role_name         = "${var.env}-oxbow"
  lambda_permissions_policy_name = "${var.env}-oxbow"

  aws_s3_locking_provider        = "dynamodb"
  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"

  dynamodb_table_name          = "${var.env}-oxbow-lock"
  logstore_dynamodb_table_name = "${var.env}-delta-logstore"

  sqs_queue_name    = "${var.env}-oxbow-queue"
  sqs_queue_name_dl = "${var.env}-oxbow-queue-dl"

  enable_bucket_notification = true

  enabled_dead_letters_monitoring = true
  dl_alert_recipients             = ["@slack-data-platform"]
  dl_warning                      = 1
  dl_critical                     = 2
  tags_monitoring                 = ["env:${var.env}", "service:oxbow"]

  tags = module.warehouse_labels.tags
}
```

`enable_bucket_notification` writes the bucket's *entire* notification
configuration, and S3 allows only one per bucket. If anything else already owns
that bucket's notifications, leave this off and add the queue over there — the
queue ARN to point at is the `ingest_queue_arn` output.

## Event delivery

Leave `sns_topic_arn` empty and S3 notifies the ingest queue directly. Set it
and the module subscribes the ingest queue to the topic instead, and sets
`UNWRAP_SNS_ENVELOPE` on whichever lambda reads the envelope first — the
group-events lambda when grouping is on, oxbow otherwise. The queue policy
follows: it admits `s3.amazonaws.com` scoped to the bucket and account, or
`sns.amazonaws.com` scoped to the topic.

## Naming limits

Several names are derived rather than passed in (`<lambda_function_name>-auto_tagging`,
`<sqs_queue_name>-auto_tagging-dl`). AWS enforces Lambda and IAM name limits at
*apply*, not at plan, so an over-long derived name fails partway through an
apply. The module checks every name it will create against its own limit at
plan time and fails with the offending name and its length.

## Lambda log groups

`manage_lambda_log_groups` (default `true`) has each lambda's CloudWatch log
group created by OpenTofu, which is what lets the logs IAM policy be scoped to
that one group instead of `*`. A deployment whose log groups already exist —
created implicitly by the Lambda service on first invocation — must either set
it to `false` or import them; see [UPGRADING.md](UPGRADING.md).

## Tests

```
tofu init -backend=false
tofu test
```

Both providers are mocked, so the suite needs no AWS or Datadog credentials and
runs on every push. It covers the toggle matrix, the event-delivery wiring, the
derived names and their limits, and the input validations.

##
Made with ❤️ by the Platform Infra Team.
