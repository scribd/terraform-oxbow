################################################################################
# Warehouse
################################################################################

variable "warehouse_bucket_arn" {
  type        = string
  description = "Warehouse bucket ARN"

  validation {
    condition     = startswith(var.warehouse_bucket_arn, "arn:") && !endswith(var.warehouse_bucket_arn, "/")
    error_message = "warehouse_bucket_arn must be a bucket ARN with no trailing slash."
  }
}

variable "warehouse_bucket_account_id" {
  type        = string
  description = "Account that owns the warehouse bucket; defaults to this account. S3 bucket ARNs carry no account id, so a cross-account bucket must name its owner or the SourceAccount conditions reject its events."
  default     = null

  validation {
    condition     = var.warehouse_bucket_account_id == null || can(regex("^[0-9]{12}$", var.warehouse_bucket_account_id))
    error_message = "warehouse_bucket_account_id must be a 12-digit account id."
  }
}

variable "s3_path" {
  type        = string
  description = "Prefix within the warehouse bucket where the parquet files are stored"

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
  })
  description = <<-EOT
    The oxbow lambda and the queue that drives it. role_name is the IAM role,
    shared with the group-events lambda when that stage is on, and policy_name
    its managed policy. queue_name is the ingest queue, used when the
    group_events stage is off; the auto-tagging stage derives its own names from
    these by appending "-auto_tagging".
  EOT
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
  description = "RUST_LOG level for the deltalake crate"
}

variable "rust_log_oxbow_debug_level" {
  type        = string
  description = "RUST_LOG level for the oxbow crate"
}

variable "aws_s3_locking_provider" {
  type        = string
  description = "Value of AWS_S3_LOCKING_PROVIDER for the oxbow lambda"
}

variable "enable_schema_evolution" {
  type        = bool
  description = "Set SCHEMA_EVOLUTION on the oxbow lambda"
  default     = true
}

variable "manage_lambda_log_groups" {
  type        = bool
  description = <<-EOT
    Manage each lambda's CloudWatch log group with OpenTofu. Leave true for new
    deployments. Existing deployments whose log groups were created implicitly by
    the Lambda service must either set this to false or import the log groups
    first -- see UPGRADING.md.
  EOT
  default     = true
}

variable "cloudwatch_logs_retention_in_days" {
  type        = number
  description = "Retention for the managed lambda log groups; null keeps logs forever"
  default     = null
}

################################################################################
# Lock tables
################################################################################

# Neither table is created here. Both must exist before the lambdas run, and
# both names are interpolated into IAM resource ARNs, so an empty one yields a
# malformed policy that fails at apply.
variable "dynamodb_table_name" {
  type        = string
  description = "Name of the existing delta-rs S3 locking table (DYNAMO_LOCK_TABLE_NAME)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{3,255}$", var.dynamodb_table_name))
    error_message = "dynamodb_table_name must be a valid DynamoDB table name (3-255 chars)."
  }
}

variable "logstore_dynamodb_table_name" {
  type        = string
  description = "Name of the existing delta logstore table (DELTA_DYNAMO_TABLE_NAME)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]{3,255}$", var.logstore_dynamodb_table_name))
    error_message = "logstore_dynamodb_table_name must be a valid DynamoDB table name (3-255 chars)."
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
  description = "Message retention for every queue this module creates"
  default     = 1209600
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
    Whether the warehouse bucket delivers object-created events straight to the
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
  })
  description = <<-EOT
    Batch events by table prefix before oxbow sees them. S3 events land on
    queue_name, this lambda groups them onto the FIFO queue, and oxbow consumes
    that instead of the standard queue. ".fifo" is appended to the FIFO names if
    absent. Shares the oxbow lambda's IAM role.
  EOT
  default     = null
}

variable "auto_tagging" {
  type = object({
    lambda_s3_bucket    = string
    lambda_s3_key       = string
    s3_notifies_queue   = optional(bool, false)
    filter_policy       = optional(string)
    filter_policy_scope = optional(string)
  })
  description = <<-EOT
    Tag objects as they land, on its own queue, lambda and IAM role. Names are
    derived from the oxbow names with an "-auto_tagging" suffix. This module
    does not route events to its queue: set sns_delivery, or wire the bucket to
    the autotag_sqs_arn output -- set s3_notifies_queue when you do that, or its
    queue policy will reject S3. The filter fields apply to its own
    subscription, so it can take a narrower slice of the topic than oxbow does.
  EOT
  default     = null

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

variable "glue_catalog_table" {
  type = object({
    database_name = string
    table_name    = string
    location_uri  = string
    description   = optional(string, "")
    columns = optional(list(object({
      name       = string
      type       = string
      parameters = optional(map(string))
    })), [])
  })
  description = "Create a parquet-backed Glue catalog table over location_uri"
  default     = null
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
