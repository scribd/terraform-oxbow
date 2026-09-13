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
```

The bucket notification and the two DynamoDB tables are the caller's: this
module takes their names and points its policies at them.

Every stage, the core included, is gated by one variable: **null turns it off, a
config object turns it on** and carries everything that stage needs. Required
fields are required by the object type, so a stage cannot be half-configured.

| Variable | null | non-null creates |
| --- | --- | --- |
| `oxbow` | no lambda, no ingest queue | the oxbow lambda, its ingest queue and DLQ, its role and policy |
| `group_events` | oxbow reads its own queue | group-events lambda, its standard queue, the FIFO queue oxbow then reads |
| `auto_tagging` | — | auto-tagging lambda, queue, own IAM role |
| `glue_create` | — | glue-create lambda, queue, Athena workgroup and results bucket |
| `glue_sync` | — | glue-sync lambda and queue |
| `dead_letter_monitoring` | — | one Datadog monitor per dead letter queue |
| `sns_delivery` | S3 feeds the ingest queue directly | a topic subscription for the ingest queue — see Event delivery |

Each queue a stage creates gets a dead letter queue, and every dead letter queue
gets a monitor when `dead_letter_monitoring` is set. The `enabled_stages` output
reports which gates are open.

Two dependencies between stages, both enforced at plan:

- `group_events` requires `oxbow` — it shares oxbow's IAM role and feeds a FIFO
  queue only oxbow consumes.
- `auto_tagging` normally derives its names from the oxbow names by appending
  `-auto_tagging`; with `oxbow = null` it must set `function_name`, `role_name`,
  `policy_name` and `queue_name` itself.

Everything else composes freely: `glue_create` and `glue_sync` each stand alone,
so the module can manage the Glue side of a warehouse whose Delta tables
something else writes.

## Usage

```hcl
module "oxbow" {
  source = "github.com/scribd/terraform-oxbow?ref=v2.0.0"

  bucket_arn = module.warehouse.s3_bucket_arn
  s3_path              = "catalogs/bronze_monolith"

  oxbow = {
    lambda_function_name = "${var.env}-oxbow"
    lambda_s3_bucket     = var.artifacts_bucket
    lambda_s3_key        = "oxbow/oxbow-lambda.zip"
    role_name            = "${var.env}-oxbow"
    policy_name          = "${var.env}-oxbow"
    queue_name           = "${var.env}-oxbow-queue"
    dl_queue_name        = "${var.env}-oxbow-queue-dl"
  }

  aws_s3_locking_provider        = "dynamodb"
  rust_log_deltalake_debug_level = "info"
  rust_log_oxbow_debug_level     = "info"

  dynamodb_table_name          = "${var.env}-oxbow-lock"
  logstore_dynamodb_table_name = "${var.env}-delta-logstore"

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
  declare. This module creates no `aws_lambda_permission`, so if you point a
  notification straight at a function rather than at its queue, grant the
  invoke yourself.
- **The lock table and the logstore table.** Pass their names as
  `dynamodb_table_name` and `logstore_dynamodb_table_name`; both are required.
  delta-rs hard-codes `key` as the lock table's partition key.

The module needs only what its policies reference: `bucket_arn` and
`s3_path` scope the object grants to
`<bucket_arn>/<s3_path>/*`, and `bucket_account_id` fills the
`aws:SourceAccount` conditions when the bucket lives in another account.
Bucket-level listing (`s3:ListBucket`) is still granted on the bucket rather
than the prefix — see the declined findings in UPGRADING.md.

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

Several names are derived rather than passed in
(`<oxbow.lambda_function_name>-auto_tagging`, `<oxbow.queue_name>-auto_tagging-dl`).
AWS enforces Lambda (64) and SQS (80) name limits at *apply*, not at plan, so an
over-long derived name fails partway through an apply. The module checks those
names at plan time and fails with the offending name and its length. IAM, Athena
and S3 names are left out because the provider already validates them
client-side at plan, and the DynamoDB tables because the module no longer
creates them.

## Required inputs

Always: `bucket_arn`, `s3_path`, `rust_log_oxbow_debug_level`.

Required only when the stage that consumes them is on — a glue-only deployment
leaves all four unset:

| Input | Required when |
| --- | --- |
| `dynamodb_table_name`, `logstore_dynamodb_table_name` | `oxbow` or `auto_tagging` is set |
| `aws_s3_locking_provider`, `rust_log_deltalake_debug_level` | `oxbow` is set |

Everything else is a stage object (null-gated, above) or a tunable with a
default:

| Variable | Default | |
| --- | --- | --- |
| `lambda_description` | `"Oxbow lambda for converting parquet files to delta tables"` | |
| `lambda_timeout` | `120` | seconds, for the oxbow, auto-tagging and glue lambdas |
| `lambda_memory_size` | `128` | MB, same three; the group-events lambda takes `group_events.memory_size` |
| `lambda_reserved_concurrent_executions` | `1` | oxbow and auto-tagging |
| `architectures` | `["x86_64"]` | or `["arm64"]` |
| `enable_schema_evolution` | `true` | sets `SCHEMA_EVOLUTION` on oxbow |
| `manage_lambda_log_groups` | `false` | see below |
| `cloudwatch_logs_retention_in_days` | `null` | null keeps logs forever |
| `sqs_visibility_timeout_seconds` | `120` | primary queues; DLQs stay at 30 |
| `sqs_delay_seconds` | `180` | primary queues; DLQs stay at 0 |
| `sqs_redrive_policy_maxReceiveCount` | `10` | receives before a message dead-letters |
| `message_retention_seconds` | `1209600` | every queue this module creates |
| `sqs_managed_sse_enabled` | `true` | SSE-SQS needs no KMS grants |
| `bucket_account_id` | `null` | defaults to the current account |
| `s3_notifies_ingest_queue` | `true` | see Event delivery |
| `tags` | `{}` | every AWS resource this module creates |

## Lambda log groups

`manage_lambda_log_groups` has each lambda's CloudWatch log group created by
OpenTofu, which is what lets the logs IAM policy be scoped to that one group
instead of `*`. It defaults to **`false`** because a log group the Lambda
service already created cannot be created again — `true` on an existing
deployment fails mid-apply with `ResourceAlreadyExistsException`. Set it `true`
on a new deployment, or after importing the groups; see
[UPGRADING.md](UPGRADING.md). With `false` the module reads each group with a
data source, which fails at plan if it does not exist yet.

## Examples

[`examples/`](examples/) has a runnable root module per deployment shape —
`minimal`, `sns-delivery`, `complete` and `glue-only` — each validated in CI.
They also show the caller's side of what this module does not own: the two
DynamoDB lock tables and, where used, the bucket notification.

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
