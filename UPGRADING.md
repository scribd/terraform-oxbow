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
- **SQS-managed encryption is switched on** (`sqs_managed_sse_enabled`, default
  `true`). This is an in-place attribute change, costs nothing, and does not
  affect S3 or SNS delivery. Set the variable to `false` to keep queues
  unencrypted.

## Fixed along the way

- The auto-tagging DLQ policy named a bare queue name where an ARN was required,
  so the policy never matched.
- The FIFO DLQ policy condition omitted the `.fifo` suffix, so it never matched
  its own queue.
- `filter_policy_scope = ""` on the glue SNS subscriptions is rejected by current
  provider versions; an empty value now means "no filter" rather than an invalid
  one.

## Interface changes

| Before | Now |
| --- | --- |
| `parquet_schema` was `list(any)` | typed `list(object({ name, type, parameters }))`; extra keys are now an error |
| `dl_warning` / `dl_critical` / `dl_ok` were `any`, default `""` | `string`, default `null`; `dl_critical` is required when monitoring is on |
| — | `manage_lambda_log_groups`, `cloudwatch_logs_retention_in_days`, `sqs_managed_sse_enabled` added |
| — | `ingest_queue_arn`, `dead_letter_queue_arns`, `lambda_role_arn`, `dynamodb_lock_table_arn` outputs added |

Existing outputs — `lambda_arn`, `sqs_queue_arn`, `autotag_sqs_arn`,
`autotag_lambda`, `dead_letters_monitor_ids` — keep their names and meaning.
