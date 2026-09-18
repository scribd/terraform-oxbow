# Examples

Each directory is a runnable root module against `../../`. Validating them is
how an interface change that breaks a caller gets caught here rather than at
someone's next upgrade, so run them after touching `variables.tf`.

| Example | Shape |
| --- | --- |
| [minimal](minimal/) | oxbow alone, fed by a bucket notification the caller owns |
| [sns-delivery](sns-delivery/) | oxbow fed from an SNS topic, plus glue-sync — the most common shape |
| [complete](complete/) | every stage on: grouping, auto-tagging, glue-create, glue-sync, Datadog monitors |
| [glue-only](glue-only/) | `oxbow = null` — catalog upkeep for Delta tables something else writes |

```
for d in examples/*/; do (cd "$d" && tofu init -backend=false && tofu validate); done
```

The account ids, buckets and topic ARNs are placeholders, so `tofu validate` is
as far as they go without real values.

## What the caller owns

Every example that runs oxbow declares the two DynamoDB tables itself, and
`minimal` declares the bucket notification. Neither belongs to the module:
S3 permits one notification configuration per bucket, and the lock tables
outlive any one pipeline. Copy those resources rather than expecting the module
to make them.
