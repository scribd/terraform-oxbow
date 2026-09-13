# Upgrading to the terraform-aws-modules rewrite

The module now builds its lambdas, queues and buckets from the published
`terraform-aws-modules` modules instead of raw resources. Every existing
resource keeps its identity: `moved.tf` relocates each one into its new address,
so **no queue, lambda or IAM role is destroyed or recreated**. Three resources
leave the module's scope entirely and are handed back to the caller rather than
destroyed, and two unused invoke permissions are deleted — see below.

It is still not a no-op plan. Read the plan before applying, and expect the
changes below.

## Before you start

- OpenTofu >= 1.12, AWS provider >= 6.42, Datadog provider >= 4.0. The AWS v6
  bump is not optional: v6 removed `aws_iam_role.managed_policy_arns`, which the
  previous version of this module used.
- Do not commit `.terraform.lock.hcl`.

## Three resources leave this module's scope

The module no longer creates the bucket's notification configuration,
the Delta lock table, or the Firehose-era parquet Glue catalog table. `moved.tf`
carries `removed` blocks with `lifecycle { destroy = false }` for all three, so
**OpenTofu forgets them and leaves them running in AWS** — without that, the
upgrade would wipe a live bucket's entire notification configuration and delete
the lock table holding Delta concurrency state.

Adopt the first two in the calling configuration or they become unmanaged drift.
The Glue catalog table needs nothing: every consumer had it switched off, so
there is nothing in state to adopt.

```hcl
# The lock table: delta-rs hard-codes "key" as the partition key.
resource "aws_dynamodb_table" "oxbow_locking" {
  name         = "${var.env}-oxbow-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "key"

  ttl {
    attribute_name = "leaseDuration"
    enabled        = true
  }

  attribute {
    name = "key"
    type = "S"
  }
}

# The bucket notification, pointed at the module's ingest queue. S3 permits one
# configuration per bucket, so this is also where every other consumer of that
# bucket's events belongs.
resource "aws_s3_bucket_notification" "warehouse" {
  bucket = module.warehouse.s3_bucket_id

  queue {
    queue_arn     = module.oxbow.ingest_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".parquet"
    filter_prefix = "catalogs/bronze_monolith/"
  }

  # ingest_queue_arn resolves from the queue, not its policy, so without this
  # S3 can reject a destination it cannot yet write to.
  depends_on = [module.oxbow]
}
```

Then import them into your own state:

```
tofu import aws_dynamodb_table.oxbow_locking <table-name>
tofu import aws_s3_bucket_notification.warehouse <bucket-name>
```

`dynamodb_table_name` and `logstore_dynamodb_table_name` are required whenever
the `oxbow` or `auto_tagging` stage is on — they are interpolated into IAM
resource ARNs, and the old `""` defaults produced a malformed policy that failed
at apply. A deployment running neither stage leaves them unset.
`enable_bucket_notification` /
`bucket_notification` are gone. The two delivery paths are now declared
independently: `s3_notifies_ingest_queue` (default `true`) and `sns_delivery`.
A topic-only deployment should set the former `false`; a deployment fed by both
needs no change.

## One manual decision: lambda log groups

The lambda module can manage each function's CloudWatch log group, which is what
lets the logs IAM policy be scoped to that one group instead of `Resource: "*"`.
Your log groups already exist — the Lambda service created them on first
invocation — and creating an existing log group fails the apply, so
`manage_lambda_log_groups` defaults to `false`.

Pick one:

**A. Keep them unmanaged** (the default, and the smallest diff):

```hcl
manage_lambda_log_groups = false   # this is now the default; nothing to set
```

The module reads each group with a data source instead. The scoped logs policy
still applies.

**B. Import them** (gets you managed retention):

```
tofu import 'module.oxbow.module.oxbow_lambda[0].aws_cloudwatch_log_group.lambda[0]' /aws/lambda/<oxbow.lambda_function_name>
```

and once per enabled stage, substituting the module name and function name:
`group_events_lambda[0]`, `auto_tagging_lambda[0]`, `glue_create_lambda[0]`,
`glue_sync_lambda[0]` — every stage module is counted, so the index is
required. Then set `manage_lambda_log_groups = true` and, if you want a
retention other than "forever", `cloudwatch_logs_retention_in_days`.

## What the plan will add

None of these replace anything; they are resources the previous layout expressed
as inline attributes or did not have at all.

- `aws_sqs_queue_policy` and `aws_sqs_queue_redrive_policy` per queue — the sqs
  module manages these as separate resources rather than inline arguments. The
  queue itself is unchanged.
- `aws_sqs_queue_redrive_allow_policy` on the dead letter queues that did not
  have one (everything except the two glue DLQs). This restricts each DLQ to its
  own source queue; previously they accepted redrive from any queue.
- `aws_iam_role_policy_attachment` replacing the removed `managed_policy_arns`.
  The policy is already attached in AWS, so the create is a no-op there.
- `aws_iam_role_policy` carrying the scoped CloudWatch Logs grant.
- `terraform_data.name_length_guard`, which holds the plan-time name length
  checks.
- With `auto_tagging` and `dead_letter_monitoring` both set, one new Datadog
  monitor: the auto-tagging DLQ was previously unmonitored.

## What the plan will change in place

- **IAM policies are rewritten to least privilege.** `dynamodb:*` becomes the six
  item-level actions delta-rs calls, `sqs:*` becomes the three actions in
  `AWSLambdaSQSQueueExecutionRole` (plus `sqs:SendMessage` on the FIFO queue for
  the group-events lambda), object
  permissions drop from the whole bucket to `<s3_path>/*` with bucket-level
  listing kept separate, and CloudWatch Logs drops from `Resource: "*"` to the
  function's own log group.
- **The dead letter queues stop being world-writable.** Every DLQ previously
  carried `Allow sqs:SendMessage` to `Principal: {"AWS": "*"}` gated by
  `ForAllValues:StringEquals` on `aws:SourceArn`. AWS evaluates `ForAllValues`
  as **true when the condition key is absent**, and `aws:SourceArn` is absent on
  a direct `SendMessage` call — so the grant was effectively unconditional and
  any AWS account could write to those queues. The statement also did nothing
  useful: redrive is performed by SQS itself and is gated by the *redrive allow
  policy*, not by the resource policy. Each DLQ now carries a single
  `Deny` to principals outside the account instead. Check CloudWatch
  `NumberOfMessagesSent` on your DLQs for unexplained volume before upgrading.
- **Queue policies are rewritten.** They previously granted `sqs:SendMessage` and
  in several cases `sqs:ReceiveMessage` to `Principal: "*"`. They now name
  `s3.amazonaws.com` or `sns.amazonaws.com`, carry an `aws:SourceAccount`
  condition on the S3 path, and never grant `ReceiveMessage` — the lambdas
  receive through their IAM role.
- **Auto-tagging queue retention rises from 4 days to 14.** Neither the
  auto-tagging queue nor its DLQ set `message_retention_seconds` before, so both
  ran on the AWS default of 345600s; they now take `message_retention_seconds`
  (default 1209600s) like every other queue. Pin that variable if you want the
  old value.
- **The FIFO dead letter queue keeps `content_based_deduplication = false`.**
  The sqs module would otherwise coalesce it from the primary FIFO queue and
  flip it to `true`; it is pinned explicitly.
- **SQS-managed encryption is switched on** (`sqs_managed_sse_enabled`, default
  `true`). This is an in-place attribute change, costs nothing, and does not
  affect S3 or SNS delivery. Set the variable to `false` to keep queues
  unencrypted.

## Removed: the S3 invoke permissions

Both `aws_lambda_permission` resources are gone and **will be destroyed** on
upgrade. They granted `s3.amazonaws.com` the right to invoke the oxbow and
auto-tagging functions, but nothing uses that right: every module instance
drives its lambda through an SQS event source mapping, and the bucket
notification this module used to write targeted the *queue*, never a function.
Checked against every live call site — `scribdinc/logs-fastly` (three
instances), `scribd/airbyte` and `scribd/terraform-payments` — none invokes a
function directly from S3.

This is the one place the upgrade destroys something, and it is a grant
removal, so it cannot break a path that was working. If you do point a bucket
notification straight at one of these functions, add your own:

```hcl
resource "aws_lambda_permission" "oxbow_from_s3" {
  statement_id   = "AllowExecutionFromS3Bucket"
  action         = "lambda:InvokeFunction"
  function_name  = module.oxbow.lambda_arn
  principal      = "s3.amazonaws.com"
  source_arn     = module.warehouse.s3_bucket_arn
  source_account = data.aws_caller_identity.current.account_id
}
```

## Also fixed in the policy audit

- **The S3 notification could race its own queue policy.** The queue policy is
  now a separate resource, and referencing `queue_arn` does not order against
  it. S3 rejects a destination it cannot yet write to, so a fresh apply could
  fail with `Unable to validate the following destination configurations`. The
  notification and the SNS subscriptions now depend on the queue modules.
- **A deployment using both delivery paths dropped S3 events.** The queue policy
  was `sns_topic_arn != "" ? sns_statement : s3_statement`, so setting a topic
  *and* `enable_bucket_notification` admitted SNS only and S3 deliveries were
  rejected silently. The statements are now additive.
- **`aws:SourceAccount` assumed the bucket was local.** New
  `bucket_account_id` names the owner when the warehouse bucket lives
  in another account; it defaults to the deploying account.
- **The lambda invoke permissions were removed entirely** — see the section
  above. They granted `s3.amazonaws.com` an invoke right no module instance
  uses.
- **A half-configured stage is now impossible.** The old `enable_*` booleans
  were independent of the config they needed, so enabling a stage without
  filling it in surfaced partway through an apply as provider errors naming
  neither the stage nor the missing field. Required fields are now required by
  the object type.
- **Each queue now gets only the publishers that actually write to it.** The
  ingest-queue policy previously keyed off "does this module own the bucket
  notification", not "does S3 publish here", so a bucket notification owned
  elsewhere *plus* `sns_delivery` admitted SNS only and S3's deliveries were
  rejected silently. Set `s3_notifies_ingest_queue = true` for that setup. The
  auto-tagging queue no longer inherits the ingest queue's S3 grant, which
  nothing exercised — set `auto_tagging.s3_notifies_queue` if a notification
  points at it.
- **`dynamodb:*` narrowed to the set delta-rs documents** plus `DescribeTable`.
  `CreateTable` is absent because neither table is created by the lambda, and
  neither is created by this module any more. Both must exist before it runs.
- **The SQS grants were narrowed again** to exactly
  `AWSLambdaSQSQueueExecutionRole`'s three actions. `sqs:GetQueueUrl` and
  `sqs:ChangeMessageVisibility` traced to no call these lambdas make.

## Fixed along the way

- The auto-tagging DLQ policy named a bare queue name where an ARN was required,
  so the policy never matched.
- The FIFO DLQ policy condition omitted the `.fifo` suffix, so it never matched
  its own queue.
- `filter_policy_scope = ""` on the glue SNS subscriptions is rejected by current
  provider versions; an empty value now means "no filter" rather than an invalid
  one.

## Removed: the parquet Glue catalog table

`enable_aws_glue_catalog_table`, `glue_database_name`, `glue_table_name`,
`glue_table_description`, `glue_location_uri` and `parquet_schema` are gone.

That resource declared a *plain parquet* Glue table over the S3 location — Hive
parquet input/output formats and `ParquetHiveSerDe`, with columns supplied by
hand. It existed to give Kinesis Firehose a schema for its JSON-to-parquet
record format conversion, which is why the old variable description called the
database "used by Kinesis to convert files into Parquet". Firehose is gone, and
every consumer had the flag set to `false`, so the resource was never created.

Note it was never a Delta registration: a plain-parquet table over that
location reads every file under the prefix and ignores `_delta_log/`, so it
would surface rows Delta has tombstoned. Delta-aware catalog registration is
what the `glue_create` and `glue_sync` stages do.

`moved.tf` carries a `removed` block with `destroy = false` for it, so any state
that does still hold one forgets it rather than deleting a live catalog entry.

## Declined

- **`s3:ListBucket` is still scoped to the bucket, not to `<s3_path>`.** Adding
  an `s3:prefix` condition would be correct least privilege, but delta-rs's
  listing prefixes are not documented and a too-tight condition stops ingestion
  rather than failing loudly. Same for `s3:ListBucketVersions`,
  `s3:GetObjectVersion` and `s3:DeleteObjectTagging`, which trace to no call the
  delta-rs docs name but were live before this change. Both want a dev apply to
  confirm before tightening; tracked separately rather than guessed at here.

## What each known call site must do

| Repo | Change needed |
| --- | --- |
| `scribdinc/logs-fastly` (×3) | SNS-fed: set `s3_notifies_ingest_queue = false`; adopt the lock table |
| `scribd/airbyte` | SNS-fed: set `s3_notifies_ingest_queue = false`; adopt the lock table |
| `scribd/terraform-payments` | Had `enable_bucket_notification = true`: adopt the bucket notification *and* the lock table; the `s3_notifies_ingest_queue` default is already correct |

All three also need the flat variables translated to the objects below, and a
decision on `manage_lambda_log_groups`.

## Interface changes

Every optional stage is now gated by a single config object: **`null` turns the
stage off, a non-null object turns it on** and carries everything that stage
needs. The `enable_*` booleans and their loose sibling variables are gone. This
is the breaking part of the upgrade — translate your module block before
planning.

| Before | Now |
| --- | --- |
| `enable_group_events` + `events_lambda_*` + `sqs_fifo_*` + `sqs_group_*` + `group_event_lambda_*` | `group_events = { lambda_function_name, lambda_s3_bucket, lambda_s3_key, queue_name, dl_queue_name, fifo_queue_name, fifo_dl_queue_name, batch_size?, maximum_batching_window_in_seconds?, max_receive_count? }` |
| `enable_auto_tagging` + `auto_tagging_s3_bucket` + `auto_tagging_s3_key` | `auto_tagging = { lambda_s3_bucket, lambda_s3_key }` |
| `enable_glue_create` + `glue_create_config` | `glue_create` (same fields; see the renames below) |
| `enable_glue_sync` + `glue_sync_config` | `glue_sync` (same fields; see the renames below) |
| `enable_bucket_notification` | gone — the caller owns the bucket notification; see above |
| `enabled_dead_letters_monitoring` + `dl_critical` + `dl_warning` + `dl_ok` + `dl_alert_recipients` + `dl_alert_message` + `tags_monitoring` + `monitoring_query_conditions` | `dead_letter_monitoring = { critical, warning?, ok?, alert_recipients?, alert_message?, tags?, query_conditions? }` |
| `lambda_function_name` + `lambda_s3_bucket` + `lambda_s3_key` + `oxbow_lambda_role_name` + `lambda_permissions_policy_name` + `sqs_queue_name` + `sqs_queue_name_dl` | `oxbow = { lambda_function_name, lambda_s3_bucket, lambda_s3_key, role_name, policy_name, queue_name, dl_queue_name }` |
| `warehouse_bucket_arn` / `warehouse_bucket_account_id` | `bucket_arn` / `bucket_account_id` — the module is generic; "warehouse" came from the retired terraform-data-warehouse lineage and described one consumer's bucket out of three |
| the oxbow lambda was always created | `oxbow` is now nullable like every other stage; leave it set to keep today's behaviour |
| `sns_topic_arn = ""` meant "no topic" | `sns_delivery = { topic_arn, filter_policy?, filter_policy_scope? }`, or null |

### SNS subscription filters

Every stage that subscribes to a topic now takes the same two fields, named
after the provider attributes they set:

- `sns_subcription_filter_policy` → `filter_policy` in both glue objects. The
  original was misspelled; the capability itself is unchanged there.
- `sns_delivery.filter_policy` / `.filter_policy_scope` and
  `auto_tagging.filter_policy` / `.filter_policy_scope` are **new**. Those two
  subscriptions previously had no filter and received the entire topic, so if
  you were filtering downstream in the lambda you can now do it at the
  subscription.
- Unset filter fields are `null`, not `""`. Current provider versions reject
  `filter_policy_scope = ""`, and the module now validates that the policy
  parses as JSON, that the scope is one of the two accepted values, and that a
  scope is never set without a policy.
- `path_regex` is optional in both glue objects and defaults to `""`.

Other input changes:

- `dead_letter_monitoring.critical` is a required `number`. It is interpolated
  into the monitor query, so a missing or non-numeric threshold used to produce
  a malformed monitor.
- `dynamodb_table_name` and `logstore_dynamodb_table_name` are required.
- `warehouse_bucket_name` is **removed**. Its only consumer was the bucket
  notification this module no longer owns; nothing else referenced it. Drop it
  from your module block.
- `bucket_account_id`, `manage_lambda_log_groups`,
  `cloudwatch_logs_retention_in_days`, `sqs_managed_sse_enabled` and
  `s3_notifies_ingest_queue` are new.
- `auto_tagging` gains optional `function_name` / `role_name` / `policy_name` /
  `queue_name` / `dl_queue_name`. Omit them and the derived names are unchanged;
  they are required only when `oxbow = null`.
- `group_events.timeout` / `.memory_size` are new. `lambda_timeout` and
  `lambda_memory_size` never applied to the group-events lambda — it ran on the
  lambda module's defaults of 3s and 128MB, which these now carry explicitly.

Outputs `lambda_arn`, `sqs_queue_arn`, `autotag_sqs_arn`, `autotag_lambda` and
`dead_letters_monitor_ids` keep their names and meaning. New:
`ingest_queue_arn`, `dead_letter_queue_arns`, `lambda_role_arn`,
`dynamodb_lock_table_arn`, `enabled_stages`.

Because the feature gates and the stage objects both changed, there is no
deprecation window — this is a major version.
