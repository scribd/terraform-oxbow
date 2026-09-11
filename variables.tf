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

variable "warehouse_bucket_name" {
  type        = string
  description = "Warehouse bucket name"
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

variable "lambda_function_name" {
  type        = string
  description = "Oxbow lambda function name"
}

variable "lambda_description" {
  type        = string
  description = "Oxbow lambda description"
  default     = "Oxbow lambda for converting parquet files to delta tables"
}

variable "lambda_s3_bucket" {
  type        = string
  description = "S3 bucket holding the oxbow lambda package"
}

variable "lambda_s3_key" {
  type        = string
  description = "S3 key of the oxbow lambda package"
}

variable "lambda_timeout" {
  type        = number
  description = "Lambda timeout in seconds"
  default     = 120
}

variable "lambda_memory_size" {
  type        = number
  description = "Lambda memory size in MB"
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

variable "oxbow_lambda_role_name" {
  type        = string
  description = "IAM role name shared by the oxbow and group-events lambdas"
}

variable "lambda_permissions_policy_name" {
  type        = string
  description = "IAM policy name for the oxbow lambda permissions"
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

variable "dynamodb_table_name" {
  type        = string
  description = "Name of the delta-rs S3 locking table created by this module"
  default     = ""
}

variable "logstore_dynamodb_table_name" {
  type        = string
  description = "Name of the pre-existing delta logstore table the lambdas write to"
  default     = ""
}

################################################################################
# Queues
################################################################################

variable "sqs_queue_name" {
  type        = string
  description = "Oxbow ingest queue name, used when enable_group_events is false"
}

variable "sqs_queue_name_dl" {
  type        = string
  description = "Oxbow ingest dead letter queue name"
}

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
# Group events
################################################################################

variable "enable_group_events" {
  type        = bool
  description = "Route events through the group-events lambda and a FIFO queue"
  default     = false
}

variable "events_lambda_function_name" {
  type        = string
  description = "Group-events lambda function name"
  default     = "events_lambda"
}

variable "events_lambda_s3_bucket" {
  type        = string
  description = "S3 bucket holding the group-events lambda package"
  default     = "events_lambda"
}

variable "events_lambda_s3_key" {
  type        = string
  description = "S3 key of the group-events lambda package"
  default     = "events_lambda"
}

variable "group_event_lambda_batch_size" {
  type        = number
  description = "Event source mapping batch size for the group-events lambda"
  default     = 10
}

variable "group_event_lambda_maximum_batching_window_in_seconds" {
  type        = number
  description = "Event source mapping batching window for the group-events lambda"
  default     = 1
}

variable "sqs_fifo_queue_name" {
  type        = string
  description = "FIFO queue name oxbow consumes when grouping is enabled; \".fifo\" is appended if absent"
  default     = "this.fifo"
}

variable "sqs_fifo_DL_queue_name" {
  type        = string
  description = "FIFO dead letter queue name; \".fifo\" is appended if absent"
  default     = "this.fifoDL"
}

variable "sqs_group_queue_name" {
  type        = string
  description = "Standard queue name the group-events lambda consumes"
  default     = "this.group"
}

variable "sqs_group_DL_queue_name" {
  type        = string
  description = "Dead letter queue name for the group-events queue"
  default     = "this.group"
}

################################################################################
# Auto tagging
################################################################################

variable "enable_auto_tagging" {
  type        = bool
  description = "Create the auto-tagging lambda and its queue"
  default     = false
}

variable "auto_tagging_s3_bucket" {
  type        = string
  description = "S3 bucket holding the auto-tagging lambda package"
  default     = ""
}

variable "auto_tagging_s3_key" {
  type        = string
  description = "S3 key of the auto-tagging lambda package"
  default     = ""
}

################################################################################
# Glue catalog table
################################################################################

variable "enable_aws_glue_catalog_table" {
  type        = bool
  description = "Create a Glue catalog table for the parquet location"
  default     = false
}

variable "glue_database_name" {
  type        = string
  description = "Glue database holding the service table"
  default     = ""
}

variable "glue_table_name" {
  type        = string
  description = "Glue service table name"
  default     = ""
}

variable "glue_table_description" {
  type        = string
  description = "Glue table description"
  default     = ""
}

variable "glue_location_uri" {
  type        = string
  description = "S3 path backing the Glue service table"
  default     = ""
}

variable "parquet_schema" {
  type = list(object({
    name       = string
    type       = string
    parameters = optional(map(string))
  }))
  description = "Columns of the Glue service table"
  default     = []
}

################################################################################
# Glue create / glue sync lambdas
################################################################################

variable "enable_glue_create" {
  type        = bool
  description = "Create the glue-create lambda, its queue and its Athena workgroup"
  default     = false
}

variable "glue_create_config" {
  type = object({
    athena_workgroup_name         = string
    athena_data_source            = string
    athena_bucket_name            = string
    lambda_s3_key                 = string
    lambda_s3_bucket              = string
    lambda_function_name          = string
    path_regex                    = string
    sns_topic_arn                 = string
    sqs_queue_name                = string
    sqs_queue_name_dl             = string
    iam_role_name                 = string
    iam_policy_name               = string
    sns_subcription_filter_policy = string
    filter_policy_scope           = string
  })
  description = "Configuration of the glue-create lambda; required when enable_glue_create is true"
  default = {
    athena_workgroup_name         = ""
    athena_data_source            = ""
    athena_bucket_name            = ""
    lambda_s3_key                 = ""
    lambda_s3_bucket              = ""
    lambda_function_name          = ""
    path_regex                    = ""
    sns_topic_arn                 = ""
    sqs_queue_name                = ""
    sqs_queue_name_dl             = ""
    iam_role_name                 = ""
    iam_policy_name               = ""
    sns_subcription_filter_policy = ""
    filter_policy_scope           = ""
  }
}

variable "enable_glue_sync" {
  type        = bool
  description = "Create the glue-sync lambda and its queue"
  default     = false
}

variable "glue_sync_config" {
  type = object({
    lambda_s3_key                 = string
    lambda_s3_bucket              = string
    lambda_function_name          = string
    path_regex                    = string
    sns_topic_arn                 = string
    sqs_queue_name                = string
    sqs_queue_name_dl             = string
    iam_role_name                 = string
    iam_policy_name               = string
    sns_subcription_filter_policy = string
    filter_policy_scope           = string
  })
  description = "Configuration of the glue-sync lambda; required when enable_glue_sync is true"
  default = {
    lambda_s3_key                 = ""
    lambda_s3_bucket              = ""
    lambda_function_name          = ""
    path_regex                    = ""
    sns_topic_arn                 = ""
    sqs_queue_name                = ""
    sqs_queue_name_dl             = ""
    iam_role_name                 = ""
    iam_policy_name               = ""
    sns_subcription_filter_policy = ""
    filter_policy_scope           = ""
  }
}

################################################################################
# Event delivery
################################################################################

variable "enable_bucket_notification" {
  type        = bool
  description = "Let this module own the warehouse bucket's notification configuration"
  default     = false
}

variable "sns_topic_arn" {
  type        = string
  description = "Subscribe the ingest queues to this topic instead of taking S3 events directly"
  default     = ""
}

################################################################################
# Monitoring
################################################################################

variable "enabled_dead_letters_monitoring" {
  type        = bool
  description = "Create a Datadog monitor per dead letter queue"
  default     = false
}

variable "dl_alert_recipients" {
  type        = list(string)
  description = "Datadog notification handles for the dead letter monitors"
  default     = []
}

variable "dl_alert_message" {
  type        = string
  description = "Extra text appended to the dead letter monitor message"
  default     = ""
}

variable "dl_warning" {
  type        = string
  description = "Dead letter monitor warning threshold"
  default     = null
}

variable "dl_critical" {
  type        = string
  description = "Dead letter monitor critical threshold"
  default     = null
}

variable "dl_ok" {
  type        = string
  description = "Dead letter monitor recovery threshold"
  default     = null
}

variable "tags_monitoring" {
  type        = list(string)
  description = "Tags applied to the Datadog monitors"
  default     = []
}

variable "monitoring_query_conditions" {
  type        = string
  description = "Extra comma-separated key:value scope terms for the monitor query"
  default     = ""
}

################################################################################
# Tagging
################################################################################

variable "tags" {
  type        = map(string)
  description = "Tags applied to every AWS resource this module creates"
  default     = {}
}
