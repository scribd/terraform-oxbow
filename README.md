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
                     group_events = null
S3 (or SNS) ──► oxbow queue ──► oxbow lambda ──► Delta table
                     │
                     └──► DLQ ──► Datadog monitor

                     group_events = {...}
S3 (or SNS) ──► group queue ──► group-events lambda ──► FIFO queue ──► oxbow lambda
                     │                                       │
                     └──► DLQ                                └──► DLQ

The bucket notification and the two DynamoDB tables are the caller's: this
module takes their names and points its policies at them.
```

Every stage below the core is gated by one variable: **null turns it off, a
config object turns it on** and carries everything that stage needs. Required
fields are required by the object type, so a stage cannot be half-configured.

| Variable | null | non-null creates |
| --- | --- | --- |
| `group_events` | oxbow reads its own queue | group-events lambda, its standard queue, the FIFO queue oxbow then reads |
| `auto_tagging` | — | auto-tagging lambda, queue, own IAM role |
| `glue_create` | — | glue-create lambda, queue, Athena workgroup and results bucket |
| `glue_sync` | — | glue-sync lambda and queue |
| `glue_catalog_table` | — | a Glue catalog table over the parquet location |
| `dead_letter_monitoring` | — | one Datadog monitor per dead letter queue |

Each queue a stage creates gets a dead letter queue, and every dead letter queue
gets a monitor when `dead_letter_monitoring` is set. The `enabled_stages` output
reports which gates are open.

## Usage

```hcl
module "oxbow" {
  source = "github.com/scribd/terraform-oxbow?ref=v2.0.0"

  warehouse_bucket_arn  = module.warehouse.s3_bucket_arn
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

  dead_letter_monitoring = {
    critical         = 2
    warning          = 1
    alert_recipients = ["@slack-data-platform"]
    tags             = ["env:${var.env}", "service:oxbow"]
  }

  tags = module.warehouse_labels.tags
}
```

Turning on a stage means filling in its object:

```hcl
  group_events = {
    lambda_function_name = "${var.env}-oxbow-group-events"
    lambda_s3_bucket     = var.artifacts_bucket
    lambda_s3_key        = "group-events/group-events.zip"
    queue_name           = "${var.env}-oxbow-group-events"
    dl_queue_name        = "${var.env}-oxbow-group-events-dl"
    fifo_queue_name      = "${var.env}-oxbow-fifo"
    fifo_dl_queue_name   = "${var.env}-oxbow-fifo-dl"
  }

  auto_tagging = {
    lambda_s3_bucket = var.artifacts_bucket
    lambda_s3_key    = "auto-tagging/auto-tagging.zip"
  }
```

## What the caller owns

S3 permits one notification configuration per bucket, and the Delta lock table
outlives any single pipeline, so neither belongs to this module:

- **The bucket notification**, if you use one. Point it at the
  `ingest_queue_arn` output; see Event delivery below for which publishers to
  declare.
- **The lock table and the logstore table.** Pass their names as
  `dynamodb_table_name` and `logstore_dynamodb_table_name`; both are required.
  delta-rs hard-codes `key` as the lock table's partition key.

Of the bucket, the module needs only what its policies reference:
`warehouse_bucket_arn` and `s3_path` scope every grant to `<bucket>/<s3_path>/*`,
and `warehouse_bucket_account_id` fills the `aws:SourceAccount` conditions when
the bucket lives in another account.

UPGRADING.md has copy-pasteable resources for both.

## Event delivery

The ingest queue can be fed by an S3 bucket notification, by an SNS topic
subscription, or by both at once. This module owns neither, so each publisher is
declared rather than inferred:

| Shape | Set | Queue policy admits |
| --- | --- | --- |
| bucket notification → SQS | nothing (defaults) | `s3.amazonaws.com`, scoped to the bucket and account |
| S3 → SNS → SQS | `sns_delivery`, `s3_notifies_ingest_queue = false` | `sns.amazonaws.com`, scoped to the topic |
| both | `sns_delivery` | both |

`s3_notifies_ingest_queue` defaults to `true` because the failure directions are
not symmetric: an unused S3 grant is a tidiness problem, whereas a missing one
means S3's deliveries are rejected and objects silently never become Delta
tables. Set it `false` on a topic-only deployment.

Setting `sns_delivery` also puts `UNWRAP_SNS_ENVELOPE` on whichever lambda reads
the envelope first — the group-events lambda when grouping is on, oxbow
otherwise.

Every stage that subscribes to a topic takes its own `filter_policy` (raw SNS
filter policy JSON) and `filter_policy_scope` (`MessageAttributes`, the AWS
default, or `MessageBody`), so each can take a different slice of the same
topic:

| Stage | Topic | Filter fields |
| --- | --- | --- |
| ingest queue | `sns_delivery.topic_arn` | `sns_delivery.filter_policy` / `.filter_policy_scope` |
| auto tagging | `sns_delivery.topic_arn` | `auto_tagging.filter_policy` / `.filter_policy_scope` |
| glue create | `glue_create.sns_topic_arn` | `glue_create.filter_policy` / `.filter_policy_scope` |
| glue sync | `glue_sync.sns_topic_arn` | `glue_sync.filter_policy` / `.filter_policy_scope` |

```hcl
  sns_delivery = {
    topic_arn     = aws_sns_topic.warehouse_events.arn
    filter_policy = jsonencode({ prefix = ["catalogs/bronze_monolith/"] })
  }
```

An omitted `filter_policy` subscribes to the whole topic. The module validates
that the policy parses as JSON, that the scope is one of the two accepted
values, and that a scope is not set without a policy — which otherwise filters
nothing while looking like it works.

## Naming limits

Several names are derived rather than passed in (`<lambda_function_name>-auto_tagging`,
`<sqs_queue_name>-auto_tagging-dl`). Lambda, SQS and DynamoDB name limits are
enforced by AWS at *apply*, not at plan, so an over-long derived name fails
partway through an apply. The module checks those names against their limits at
plan time and fails with the offending name and its length. IAM, Athena and S3
names are left out: the provider already validates them client-side at plan.

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
runs on every push. It covers the feature gates, the event-delivery wiring, the
derived names and their limits, the policy defects found while auditing the
rewrite, and the input validations.

##
Made with ❤️ by the Platform Infra Team.
