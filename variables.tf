################################################################################
# Bucket
################################################################################

variable "bucket_arn" {
  type        = string
  description = "ARN of the bucket the parquet objects land in and the Delta tables are written to"

  validation {
    condition     = startswith(var.bucket_arn, "arn:") && !endswith(var.bucket_arn, "/")
    error_message = "bucket_arn must be a bucket ARN with no trailing slash."
  }
}

variable "bucket_account_id" {
  type        = string
  description = "Account that owns the bucket; defaults to this account. S3 bucket ARNs carry no account id, so a cross-account bucket must name its owner or the SourceAccount conditions reject its events."
  default     = null

  validation {
    condition     = var.bucket_account_id == null || can(regex("^[0-9]{12}$", var.bucket_account_id))
    error_message = "bucket_account_id must be a 12-digit account id."
  }
}

variable "s3_path" {
  type        = string
  description = "Key prefix within the bucket where the parquet files are stored"

  validation {
    condition     = !startswith(var.s3_path, "/") && !endswith(var.s3_path, "/")
    error_message = "s3_path must not start or end with a slash."
  }
}

################################################################################
# Oxbow lambda
################################################################################

variable "oxbow" {
  type = object({
    lambda_function_name = string
    lambda_s3_bucket     = string
    lambda_s3_key        = string
    role_name            = string
    policy_name          = string
    queue_name           = string
    dl_queue_name        = string
    manage_log_group     = optional(bool)
  })
  description = <<-EOT
    The oxbow lambda and the queue that drives it; null turns the stage off, so
    the module can deploy auto-tagging or the glue stages on their own.
    role_name is the IAM role, shared with the group-events lambda when that
    stage is on, and policy_name its managed policy. queue_name is the ingest
    queue, used when the group_events stage is off; the auto-tagging stage
    derives its own names from these unless it sets its own.
  EOT
  default     = null
}

variable "lambda_description" {
  type        = string
  description = "Oxbow lambda description"
  default     = "Oxbow lambda for converting parquet files to delta tables"
}

variable "lambda_timeout" {
  type        = number
  description = "Lambda timeout in seconds for the oxbow, auto-tagging and glue lambdas. The group-events lambda takes group_events.timeout."
  default     = 120
}

variable "lambda_memory_size" {
  type        = number
  description = "Lambda memory size in MB for the oxbow, auto-tagging and glue lambdas. The group-events lambda takes group_events.memory_size."
  default     = 128
}

variable "lambda_reserved_concurrent_executions" {
  type        = number
  description = "Reserved concurrent executions for the oxbow and auto-tagging lambdas"
  default     = 1
}

variable "architectures" {
  type        = list(string)
  description = "Instruction set architecture for the lambda functions"
  default     = ["x86_64"]

  validation {
    condition     = length(var.architectures) == 1 && contains(["x86_64", "arm64"], var.architectures[0])
    error_message = "architectures must be exactly one of [\"x86_64\"] or [\"arm64\"]."
  }
}

variable "rust_log_deltalake_debug_level" {
  type        = string
  description = "RUST_LOG level for the deltalake crate; required when the oxbow stage is on"
  default     = null

  validation {
    condition     = var.oxbow == null || var.rust_log_deltalake_debug_level != null
    error_message = "rust_log_deltalake_debug_level is required when the oxbow stage is on."
  }
}

variable "rust_log_oxbow_debug_level" {
  type        = string
  description = "RUST_LOG level for the oxbow crate"
}

variable "aws_s3_locking_provider" {
  type        = string
  description = "Value of AWS_S3_LOCKING_PROVIDER for the oxbow lambda; required when the oxbow stage is on"
  default     = null

  validation {
    condition     = var.oxbow == null || var.aws_s3_locking_provider != null
    error_message = "aws_s3_locking_provider is required when the oxbow stage is on."
  }
}

variable "enable_schema_evolution" {
  type        = bool
  description = "Set SCHEMA_EVOLUTION on the oxbow lambda"
  default     = true
}

variable "manage_lambda_log_groups" {
  type        = bool
  description = <<-EOT
    Default for every stage: manage that lambda's CloudWatch log group with
    OpenTofu, which is what lets the logs policy be scoped to that one group.
    False because a log group the Lambda service already created cannot be
    created again, so true on an existing deployment fails mid-apply with
    ResourceAlreadyExistsException; false reads the group with a data source
    instead, which fails at plan if it does not exist yet. Neither state suits a
    deployment that has some lambdas already and is adding another, so each stage
    object can override this with its own manage_log_group.
  EOT
  default     = false
}

variable "cloudwatch_logs_retention_in_days" {
  type        = number
  description = "Retention for the managed lambda log groups; null keeps logs forever"
  default     = null
}

################################################################################
# Lock tables
################################################################################

# Neither table is created here; both must exist before oxbow runs. Only the
# oxbow stage touches them, so a deployment without it leaves them null.
variable "dynamodb_table_name" {
  type        = string
  description = "Name of the existing delta-rs S3 locking table (DYNAMO_LOCK_TABLE_NAME); required when the oxbow stage is on"
  default     = null

  validation {
    condition     = var.dynamodb_table_name == null || can(regex("^[A-Za-z0-9_.-]{3,255}$", var.dynamodb_table_name))
    error_message = "dynamodb_table_name must be a valid DynamoDB table name (3-255 chars)."
  }

  validation {
    condition     = var.oxbow == null || var.dynamodb_table_name != null
    error_message = "dynamodb_table_name is required when the oxbow stage is on."
  }
}

variable "logstore_dynamodb_table_name" {
  type        = string
  description = "Name of the existing delta logstore table (DELTA_DYNAMO_TABLE_NAME); required when the oxbow stage is on"
  default     = null

  validation {
    condition     = var.logstore_dynamodb_table_name == null || can(regex("^[A-Za-z0-9_.-]{3,255}$", var.logstore_dynamodb_table_name))
    error_message = "logstore_dynamodb_table_name must be a valid DynamoDB table name (3-255 chars)."
  }

  validation {
    condition     = var.oxbow == null || var.logstore_dynamodb_table_name != null
    error_message = "logstore_dynamodb_table_name is required when the oxbow stage is on."
  }
}

################################################################################
# Queues
################################################################################

variable "sqs_visibility_timeout_seconds" {
  type        = number
  description = "Visibility timeout for the primary queues"
  default     = 120
}

variable "sqs_delay_seconds" {
  type        = number
  description = "Delivery delay for the primary queues"
  default     = 180
}

variable "sqs_redrive_policy_maxReceiveCount" {
  type        = number
  description = "Receives before a message is moved to the dead letter queue"
  default     = 10
}

variable "message_retention_seconds" {
  type        = number
  description = "Message retention for every queue and dead letter queue this module creates. Defaults to 1209600s (14 days), the SQS maximum, so a failed event has the longest possible window to be inspected and redriven."
  default     = 1209600

  validation {
    condition     = var.message_retention_seconds >= 60 && var.message_retention_seconds <= 1209600
    error_message = "message_retention_seconds must be between 60 (1 minute) and 1209600 (14 days, the SQS maximum)."
  }
}

variable "sqs_managed_sse_enabled" {
  type        = bool
  description = "Enable SQS-managed server-side encryption on every queue this module creates"
  default     = true
}

################################################################################
# Event delivery
################################################################################

variable "sns_delivery" {
  type = object({
    topic_arn           = string
    filter_policy       = optional(string)
    filter_policy_scope = optional(string)
  })
  description = <<-EOT
    Subscribe the ingest queue to this topic instead of taking S3 events
    directly. filter_policy is the raw SNS subscription filter policy JSON and
    filter_policy_scope is MessageAttributes (the AWS default) or MessageBody.
  EOT
  default     = null

  validation {
    condition     = var.sns_delivery == null || startswith(var.sns_delivery.topic_arn, "arn:")
    error_message = "sns_delivery.topic_arn must be a topic ARN."
  }

  validation {
    condition     = var.sns_delivery == null || var.sns_delivery.filter_policy == null || can(jsondecode(var.sns_delivery.filter_policy))
    error_message = "sns_delivery.filter_policy must be valid JSON."
  }

  validation {
    condition     = var.sns_delivery == null || var.sns_delivery.filter_policy_scope == null || contains(["MessageAttributes", "MessageBody"], coalesce(var.sns_delivery.filter_policy_scope, "x"))
    error_message = "sns_delivery.filter_policy_scope must be MessageAttributes, MessageBody, or null."
  }

  validation {
    condition     = var.sns_delivery == null || var.sns_delivery.filter_policy_scope == null || var.sns_delivery.filter_policy != null
    error_message = "sns_delivery.filter_policy_scope has no effect without filter_policy."
  }
}

################################################################################
# Optional stages
#
# Every variable below gates one feature: null turns the stage off, a non-null
# object turns it on and carries everything that stage needs. Required fields
# are required by the type, so an enabled stage cannot be half-configured.
################################################################################

variable "s3_notifies_ingest_queue" {
  type        = bool
  description = <<-EOT
    Whether the bucket delivers object-created events straight to the
    ingest queue, i.e. an S3 notification configuration (owned by the caller)
    targets it. Independent of sns_delivery: a queue can be fed by a bucket
    notification, by a topic subscription, or by both at once. Set this false
    on a topic-only deployment so the queue policy does not carry an S3 grant
    nothing uses.
  EOT
  default     = true
}

variable "group_events" {
  type = object({
    lambda_function_name               = string
    lambda_s3_bucket                   = string
    lambda_s3_key                      = string
    queue_name                         = string
    dl_queue_name                      = string
    fifo_queue_name                    = string
    fifo_dl_queue_name                 = string
    batch_size                         = optional(number, 10)
    maximum_batching_window_in_seconds = optional(number, 1)
    max_receive_count                  = optional(number, 8)
    timeout                            = optional(number, 3)
    memory_size                        = optional(number, 128)
    manage_log_group                   = optional(bool)
  })
  description = <<-EOT
    Batch events by table prefix before oxbow sees them. S3 events land on
    queue_name, this lambda groups them onto the FIFO queue, and oxbow consumes
    that instead of the standard queue. ".fifo" is appended to the FIFO names if
    absent. Shares the oxbow lambda's IAM role, and feeds a FIFO queue only
    oxbow consumes, so it requires the oxbow stage.
  EOT
  default     = null

  validation {
    condition     = var.group_events == null || var.oxbow != null
    error_message = "group_events requires the oxbow stage: it shares oxbow's IAM role and feeds a FIFO queue only oxbow consumes."
  }
}

variable "auto_tagging" {
  type = object({
    lambda_s3_bucket    = string
    lambda_s3_key       = string
    function_name       = optional(string)
    role_name           = optional(string)
    policy_name         = optional(string)
    queue_name          = optional(string)
    dl_queue_name       = optional(string)
    s3_notifies_queue   = optional(bool, false)
    manage_log_group    = optional(bool)
    filter_policy       = optional(string)
    filter_policy_scope = optional(string)
  })
  description = <<-EOT
    Tag objects as they land, on its own queue, lambda and IAM role. The name
    fields default to the oxbow names with an "-auto_tagging" suffix, and are
    required when the oxbow stage is off since there is then nothing to derive
    from. dl_queue_name defaults to queue_name plus "-dl". This module
    does not route events to its queue: set sns_delivery, or wire the bucket to
    the autotag_sqs_arn output -- set s3_notifies_queue when you do that, or its
    queue policy will reject S3. The filter fields apply to its own
    subscription, so it can take a narrower slice of the topic than oxbow does.
  EOT
  default     = null

  validation {
    condition = var.auto_tagging == null || var.oxbow != null || alltrue([
      for f in [
        var.auto_tagging.function_name,
        var.auto_tagging.role_name,
        var.auto_tagging.policy_name,
        var.auto_tagging.queue_name,
      ] : f != null
    ])
    error_message = "With the oxbow stage off, auto_tagging must set function_name, role_name, policy_name and queue_name -- there are no oxbow names to derive them from."
  }

  validation {
    condition     = var.auto_tagging == null || var.auto_tagging.filter_policy == null || can(jsondecode(var.auto_tagging.filter_policy))
    error_message = "auto_tagging.filter_policy must be valid JSON."
  }

  validation {
    condition     = var.auto_tagging == null || var.auto_tagging.filter_policy_scope == null || contains(["MessageAttributes", "MessageBody"], coalesce(var.auto_tagging.filter_policy_scope, "x"))
    error_message = "auto_tagging.filter_policy_scope must be MessageAttributes, MessageBody, or null."
  }

  validation {
    condition     = var.auto_tagging == null || var.auto_tagging.filter_policy_scope == null || var.auto_tagging.filter_policy != null
    error_message = "auto_tagging.filter_policy_scope has no effect without filter_policy."
  }
}

variable "glue_create" {
  type = object({
    athena_workgroup_name = string
    athena_data_source    = string
    athena_bucket_name    = string
    lambda_s3_bucket      = string
    lambda_s3_key         = string
    lambda_function_name  = string
    sns_topic_arn         = string
    sqs_queue_name        = string
    sqs_queue_name_dl     = string
    iam_role_name         = string
    iam_policy_name       = string
    path_regex            = optional(string, "")
    filter_policy         = optional(string)
    filter_policy_scope   = optional(string)
  })
  description = "Create Glue catalog tables from the S3 path, running DDL through a dedicated Athena workgroup"
  default     = null

  validation {
    condition     = var.glue_create == null || length(var.glue_create.athena_bucket_name) <= 63
    error_message = "glue_create.athena_bucket_name exceeds the 63-character S3 bucket limit."
  }

  validation {
    condition     = var.glue_create == null || startswith(var.glue_create.sns_topic_arn, "arn:")
    error_message = "glue_create.sns_topic_arn must be a topic ARN."
  }

  validation {
    condition     = var.glue_create == null || var.glue_create.filter_policy == null || can(jsondecode(var.glue_create.filter_policy))
    error_message = "glue_create.filter_policy must be valid JSON."
  }

  validation {
    condition     = var.glue_create == null || var.glue_create.filter_policy_scope == null || contains(["MessageAttributes", "MessageBody"], coalesce(var.glue_create.filter_policy_scope, "x"))
    error_message = "glue_create.filter_policy_scope must be MessageAttributes, MessageBody, or null."
  }

  validation {
    condition     = var.glue_create == null || var.glue_create.filter_policy_scope == null || var.glue_create.filter_policy != null
    error_message = "glue_create.filter_policy_scope has no effect without filter_policy."
  }
}

variable "glue_sync" {
  type = object({
    lambda_s3_bucket     = string
    lambda_s3_key        = string
    lambda_function_name = string
    sns_topic_arn        = string
    sqs_queue_name       = string
    sqs_queue_name_dl    = string
    iam_role_name        = string
    iam_policy_name      = string
    path_regex           = optional(string, "")
    filter_policy        = optional(string)
    filter_policy_scope  = optional(string)
  })
  description = "Keep existing Glue catalog tables in step with the Delta tables oxbow writes"
  default     = null

  validation {
    condition     = var.glue_sync == null || startswith(var.glue_sync.sns_topic_arn, "arn:")
    error_message = "glue_sync.sns_topic_arn must be a topic ARN."
  }

  validation {
    condition     = var.glue_sync == null || var.glue_sync.filter_policy == null || can(jsondecode(var.glue_sync.filter_policy))
    error_message = "glue_sync.filter_policy must be valid JSON."
  }

  validation {
    condition     = var.glue_sync == null || var.glue_sync.filter_policy_scope == null || contains(["MessageAttributes", "MessageBody"], coalesce(var.glue_sync.filter_policy_scope, "x"))
    error_message = "glue_sync.filter_policy_scope must be MessageAttributes, MessageBody, or null."
  }

  validation {
    condition     = var.glue_sync == null || var.glue_sync.filter_policy_scope == null || var.glue_sync.filter_policy != null
    error_message = "glue_sync.filter_policy_scope has no effect without filter_policy."
  }
}

variable "dead_letter_monitoring" {
  type = object({
    critical         = number
    warning          = optional(number)
    ok               = optional(number)
    alert_recipients = optional(list(string), [])
    alert_message    = optional(string, "")
    tags             = optional(list(string), [])
    query_conditions = optional(string, "")
  })
  description = "One Datadog monitor per dead letter queue this module creates. query_conditions is extra comma-separated key:value scope terms for the monitor query."
  default     = null
}

################################################################################
# Tagging
################################################################################

variable "tags" {
  type        = map(string)
  description = "Tags applied to every AWS resource this module creates"
  default     = {}
}
