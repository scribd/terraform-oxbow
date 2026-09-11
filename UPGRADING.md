# Upgrading to the terraform-aws-modules rewrite

The module now builds its lambdas, queues and buckets from the published
`terraform-aws-modules` modules instead of raw resources. Every existing
resource keeps its identity: `moved.tf` relocates each one into its new address,
so **no queue, lambda, IAM role or DynamoDB table is destroyed or recreated**.

It is still not a no-op plan. Read the plan before applying, and expect the
changes below.

## Before you start

- OpenTofu >= 1.12, AWS provider >= 6.42, Datadog provider >= 4.0. The AWS v6
  bump is not optional: v6 removed `aws_iam_role.managed_policy_arns`, which the
  previous version of this module used.
- Do not commit `.terraform.lock.hcl`.

## One manual decision: lambda log groups

The lambda module manages each function's CloudWatch log group, which is what
lets the logs IAM policy be scoped to that one group instead of `Resource: "*"`.
Your log groups already exist — the Lambda service created them on first
invocation — and creating an existing log group fails the apply.

Pick one:

**A. Keep them unmanaged** (smallest diff):

```hcl
manage_lambda_log_groups = false
```

The module reads each group with a data source instead. The scoped logs policy
still applies.

**B. Import them** (gets you managed retention):

```
tofu import 'module.oxbow.module.oxbow_lambda.aws_cloudwatch_log_group.lambda[0]' /aws/lambda/<lambda_function_name>
```

and once per enabled stage, substituting the module name and function name:
`group_events_lambda`, `auto_tagging_lambda`, `glue_create_lambda`,
`glue_sync_lambda`. Then set `cloudwatch_logs_retention_in_days` if you want a
retention other than "forever".

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
- With `enable_auto_tagging` and `enabled_dead_letters_monitoring` both on, one
  new Datadog monitor: the auto-tagging DLQ was previously unmonitored.

## What the plan will change in place

- **IAM policies are rewritten to least privilege.** `dynamodb:*` becomes the six
  item-level actions delta-rs calls, `sqs:*` becomes the five consumer actions
  (plus `sqs:SendMessage` on the FIFO queue for the group-events lambda), object
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

## Two resources are replaced, not updated

Adding `source_account` to `aws_lambda_permission` is a ForceNew attribute, so
the two invoke permissions (`oxbow_from_s3` and, if auto-tagging is on,
`auto_tagging`) are removed and re-added rather than updated. That is the only
exception to "nothing is destroyed" above. It matters only if a bucket
notification owned outside this module invokes those functions *directly* —
S3 does not retry an authorization failure, so events during the short
replacement window would be lost. If that describes your setup, apply during a
quiet period.

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
  `warehouse_bucket_account_id` names the owner when the warehouse bucket lives
  in another account; it defaults to the deploying account.
- **The lambda invoke permissions had no `source_account`.** S3 bucket names are
  global, so a same-named bucket in another account could invoke the functions.
  Neither lambda is invoked by S3 *within* this module — both are driven by an
  event source mapping — but the permissions are kept for consumers who wire a
  bucket straight at the function.
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
  `CreateTable` is deliberately absent: this module creates the lock table, and
  the logstore table is an existing input. If you point
  `logstore_dynamodb_table_name` at a table that does not exist, create it out
  of band — the lambda can no longer create it for you.

## Fixed along the way

- The auto-tagging DLQ policy named a bare queue name where an ARN was required,
  so the policy never matched.
- The FIFO DLQ policy condition omitted the `.fifo` suffix, so it never matched
  its own queue.
- `filter_policy_scope = ""` on the glue SNS subscriptions is rejected by current
  provider versions; an empty value now means "no filter" rather than an invalid
  one.

## Declined

- **`s3:ListBucket` is still scoped to the bucket, not to `<s3_path>`.** Adding
  an `s3:prefix` condition would be correct least privilege, but delta-rs's
  listing prefixes are not documented and a too-tight condition stops ingestion
  rather than failing loudly. Same for `s3:ListBucketVersions`,
  `s3:GetObjectVersion` and `s3:DeleteObjectTagging`, which trace to no call the
  delta-rs docs name but were live before this change. Both want a dev apply to
  confirm before tightening; tracked separately rather than guessed at here.

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
| `enable_aws_glue_catalog_table` + `glue_database_name` + `glue_table_name` + `glue_table_description` + `glue_location_uri` + `parquet_schema` | `glue_catalog_table = { database_name, table_name, location_uri, description?, columns? }` |
| `enable_glue_create` + `glue_create_config` | `glue_create` (same fields; see the renames below) |
| `enable_glue_sync` + `glue_sync_config` | `glue_sync` (same fields; see the renames below) |
| `enable_bucket_notification` | `bucket_notification = {}` — or `{ events?, filter_prefix?, filter_suffix? }`, previously hard-coded |
| `enabled_dead_letters_monitoring` + `dl_critical` + `dl_warning` + `dl_ok` + `dl_alert_recipients` + `dl_alert_message` + `tags_monitoring` + `monitoring_query_conditions` | `dead_letter_monitoring = { critical, warning?, ok?, alert_recipients?, alert_message?, tags?, query_conditions? }` |
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

- `parquet_schema` was `list(any)`; the replacement `glue_catalog_table.columns`
  is typed `list(object({ name, type, parameters }))`, so extra keys are now an
  error.
- `dead_letter_monitoring.critical` is a required `number`. It is interpolated
  into the monitor query, so a missing or non-numeric threshold used to produce
  a malformed monitor.
- `warehouse_bucket_account_id`, `manage_lambda_log_groups`,
  `cloudwatch_logs_retention_in_days`, `sqs_managed_sse_enabled` and
  `s3_notifies_ingest_queue` are new.
- `group_events.timeout` / `.memory_size` are new. `lambda_timeout` and
  `lambda_memory_size` never applied to the group-events lambda — it ran on the
  lambda module's defaults of 3s and 128MB, which these now carry explicitly.

Outputs `lambda_arn`, `sqs_queue_arn`, `autotag_sqs_arn`, `autotag_lambda` and
`dead_letters_monitor_ids` keep their names and meaning. New:
`ingest_queue_arn`, `dead_letter_queue_arns`, `lambda_role_arn`,
`dynamodb_lock_table_arn`, `enabled_stages`.

Because the feature gates and the stage objects both changed, there is no
deprecation window — this is a major version.
