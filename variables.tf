variable "glue_database_name" {
  type        = string
  default     = ""
  description = "Glue database name (This is service database managed by TF databases, used by Kinesis to convert files into Parquet)"
}

variable "glue_location_uri" {
  type        = string
  default     = ""
  description = "Glue location uri - S3 path for the glue service table"
}

variable "glue_table_name" {
  type        = string
  default     = ""
  description = "Glue table name - service table name"
}

variable "glue_table_description" {
  type        = string
  default     = ""
  description = "Glue table description"
}

variable "parquet_schema" {
  type        = list(any)
  description = "Parquet schema, can be different that why type is not so straight"
  default     = []
}

variable "kinesis_s3_prefix" {
  default     = ""
  type        = string
  description = "Kinesis s3 prefix - s3 location where the files will be output"
}

variable "kinesis_delivery_stream_name" {
  type        = string
  default     = ""
  description = "Kinesis delivery stream name"
}

variable "warehouse_bucket_arn" {
  type        = string
  description = "Warehouse bucket arn"
}

variable "warehouse_bucket_name" {
  type        = string
  description = "Warehouse bucket name"
}

variable "kinesis_s3_errors_prefix" {
  type        = string
  default     = ""
  description = "Kinesiss3 errors prefix - s3 location where the files will be output"
}

variable "lambda_function_name" {
  type        = string
  description = "Lambda function name"
}

variable "events_lambda_function_name" {
  type        = string
  default     = "events_lambda"
  description = "Events Lambda function name"
}

variable "lambda_description" {
  type        = string
  description = "Lambda description"
  default     = "Oxbow lambda for converting parquet files to delta tables"
}

variable "lambda_timeout" {
  type        = number
  description = "Lambda timeout"
  default     = 120
}

variable "lambda_s3_key" {
  type        = string
  description = "Lambda s3 key - lambda path on S3 and file name filename"
}

variable "lambda_s3_bucket" {
  type        = string
  description = "Lambda s3 bucket where lambda is stored"
}

variable "lambda_memory_size" {
  type        = number
  default     = 128
  description = "Lambda memory size"
}

variable "events_lambda_s3_key" {
  default     = "events_lambda"
  type        = string
  description = "Events Lambda s3 key - lambda path on S3 and file name filename"
}

variable "events_lambda_s3_bucket" {
  type        = string
  default     = "events_lambda"
  description = "Events Lambda s3 bucket where lambda is stored"
}

variable "lambda_permissions_policy_name" {
  type        = string
  description = ""
}

variable "lambda_reserved_concurrent_executions" {
  type        = number
  description = "Lambda reserved concurrent executions"
  default     = 1
}

variable "kinesis_policy_name" {
  type        = string
  default     = ""
  description = "Kinesis policy name"
}

variable "kinesis_policy_description" {
  type        = string
  description = "Kinesis policy description"
  default     = ""
}

variable "rust_log_deltalake_debug_level" {
  type        = string
  description = "Rust log deltalake debug level"
}

variable "rust_log_oxbow_debug_level" {
  type        = string
  description = "Rust log oxbow debug level"
}

variable "aws_s3_locking_provider" {
  type        = string
  description = "Aws s3 locking provider"
}

variable "dynamodb_table_name" {
  type        = string
  default     = ""
  description = "Dynamodb table name"
}

variable "sqs_queue_name" {
  type        = string
  description = "Sqs queue name"
}

variable "sqs_visibility_timeout_seconds" {
  type        = number
  default     = 120
  description = "Sqs visibility timeout seconds"
}

variable "sqs_delay_seconds" {
  type        = number
  default     = 180
  description = "Sqs delivery delay seconds"
}

variable "sqs_redrive_policy_maxReceiveCount" {
  type        = number
  default     = 10
  description = "Sqs maxReceiveCount"
}

variable "sqs_fifo_queue_name" {
  type        = string
  default     = "this.fifo"
  description = "Sqs FIFO queue name"
}

variable "sqs_fifo_DL_queue_name" {
  type        = string
  default     = "this.fifoDL"
  description = "Sqs DL FIFO queue name"
}

variable "sqs_group_queue_name" {
  type        = string
  default     = "this.group"
  description = "Sqs group queue name"
}

variable "sqs_group_DL_queue_name" {
  type        = string
  default     = "this.group"
  description = "Sqs group queue name"
}

variable "sqs_queue_name_dl" {
  type        = string
  description = "Sqs queue name - dead letters"
}

variable "lambda_kinesis_role_name" {
  type        = string
  description = "Lambda kinesis IAM role name"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "A mapping of tags to assign to the resource"
}

variable "s3_path" {
  type        = string
  description = "s3_path - where the files are going to be stored"
}

# monitoring
variable "enabled_dead_letters_monitoring" {
  type        = bool
  description = "Enable monitoring"
  default     = false
}

variable "dl_alert_recipients" {
  type        = list(string)
  default     = []
  description = "List of the alert recipients"
}

variable "dl_warning" {
  type        = number
  default     = 0
  description = "Dead letters warning value"
}

variable "dl_critical" {
  type        = number
  default     = 0
  description = "Dead letters critical value"
}

variable "tags_monitoring" {
  type        = list(string)
  default     = []
  description = "A list of tags to assign to the monitoring resource"
}

variable "enable_aws_glue_catalog_table" {
  type        = bool
  description = "Enable glue catalog table"
  default     = false
}

variable "enable_kinesis_firehose_delivery_stream" {
  type        = bool
  description = "Enable firehose delivery stream"
  default     = false
}

variable "enable_bucket_notification" {
  type        = bool
  description = "Enable enable_bucket_notification"
  default     = false
}

variable "enable_group_events" {
  type        = bool
  description = "Enable group events"
  default     = false
}
