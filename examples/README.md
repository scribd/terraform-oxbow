# Examples

Each directory is a runnable root module against `../../`. They exist to be
validated in CI, so an interface change that breaks a caller fails the build
rather than the next upgrade.

| Example | Shape |
| --- | --- |
| [minimal](minimal/) | oxbow alone, fed by a bucket notification the caller owns |
| [sns-delivery](sns-delivery/) | oxbow fed from an SNS topic, plus glue-sync — what logs-fastly and airbyte run |
| [complete](complete/) | every stage on: grouping, auto-tagging, glue-create, glue-sync, Datadog monitors |
| [glue-only](glue-only/) | `oxbow = null` — catalog upkeep for Delta tables something else writes |

```
cd examples/minimal
tofu init -backend=false
tofu validate
```

They are not applied in CI and the account ids, buckets and topic ARNs are
placeholders, so `tofu plan` against them needs real values.

## What the caller owns

Every example that runs oxbow declares the two DynamoDB tables itself, and
`minimal` declares the bucket notification. Neither belongs to the module:
S3 permits one notification configuration per bucket, and the lock tables
outlive any one pipeline. Copy those resources rather than expecting the module
to make them.

## Known friction

`glue-only` has to pass `rust_log_deltalake_debug_level`,
`aws_s3_locking_provider`, `dynamodb_table_name` and
`logstore_dynamodb_table_name` even though nothing in that deployment reads a
Delta log or takes a lock — they are required inputs that only the oxbow and
auto-tagging stages consume. Moving them onto the stage objects that use them
would fix it.
