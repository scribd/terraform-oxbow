# terraform-oxbow
*Terraform module to manage oxbow Lambda and its components.
We can have the following components in AWS:
1. Lambda
2. Kinesis Firehost
3. SQS 
4. SQS dead letters
5. IAM policy
6. S3 bucket notifications
7. Dynamo DB table
8. Glue catalog
9. Glue table

### examples:
if we need Glue catalog and table
```
enable_aws_glue_catalog_table = true
```
if we need Kinesis firehost delivery stream 
```
enable_kinesis_firehose_delivery_stream = true
```
if we need s3 bucket notification 
```
enable_bucket_notification = true
```
if we need advanced Oxbow lambda setup for myltiprefiltered optimization
```
enable_group_events = true
```

this is a good start
```
module "app_mesh_logs" {
  source = ""

  enable_aws_glue_catalog_table           = true
  enable_kinesis_firehose_delivery_stream = true
  enable_bucket_notification              = false


  warehouse_bucket_arn  = ""
  warehouse_bucket_name = ""

  # bucket notification because of limits is configured in file s3_bucket_notification_configuration.tf

  # the place where we store files
  s3_path = ""

  lambda_kinesis_role_name              = ""
  lambda_function_name                  = ""
  lambda_description                    = ""
  lambda_s3_key                         = ""
  lambda_s3_bucket                      = ""
  lambda_reserved_concurrent_executions = 1
  lambda_permissions_policy_name        = ""
  rust_log_deltalake_debug_level        = "debug"
  rust_log_oxbow_debug_level            = "debug"

  sqs_queue_name      = "${var.env}--queue"
  sqs_queue_name_dl   = "${var.env}--queue-dl"
  dynamodb_table_name = "${var.env}-oxbow-lock"

  kinesis_delivery_stream_name = ""
  kinesis_s3_prefix            = ""
  kinesis_s3_errors_prefix     = ""
  kinesis_policy_name          = ""
  kinesis_policy_description   = ""

  # We have dedicated service Database for Kinesis file conversions
  glue_database_name     = ""
  glue_table_name        = ""
  glue_location_uri      = ""
  glue_table_description = ""
  # this schema is required by Kinesis to convert input into Parquet
  parquet_schema = ["parquet_schema]
  aws_s3_locking_provider = "dynamodb"

  enabled_dead_letters_monitoring = true
  dl_alert_recipients             = ["@slack-chanel"]
  dl_warning                      = 1
  dl_critical                     = 2
  tags_monitoring                 = ["slack-chanel", "env:${var.env}", "service:${var.env}-project-name"]

  tags = merge({ project = "project_name" }, module.warehouse_labels.tags)
}
```



### Important to know:
Due to Terraform AWS S3 bucket notifications limitation we can have just one S3 bucket notification configuration per AWS account.
`
S3 Buckets only support a single notification configuration. Declaring multiple aws_s3_bucket_notification resources to the same S3 Bucket will cause a perpetual difference in configuration. See the example "Trigger multiple Lambda functions" for an option.
`
https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification
##
Made with ❤️ by the Platform Infra Team.
