# State moves for the rewrite onto terraform-aws-modules. Every address below
# existed in the previous layout; without these an upgrade plans a destroy and
# recreate of live queues, lambdas and the lock table. See UPGRADING.md for the
# few resources that cannot be moved.

################################################################################
# Oxbow
#
# module.oxbow_lambda has no count, so its targets are indexed on the resource
# (`...this[0]`). Every stage module is counted, so those targets index the
# module and move the resource whole (`module.x[0]...this`), which preserves the
# instance key. Both forms are deliberate; do not "normalise" one into the other.
################################################################################

moved {
  from = aws_lambda_function.this_lambda
  to   = module.oxbow_lambda.aws_lambda_function.this[0]
}

moved {
  from = aws_iam_role.oxbow_lambda_role
  to   = module.oxbow_lambda.aws_iam_role.lambda[0]
}

moved {
  from = aws_lambda_event_source_mapping.this_lambda_events
  to   = module.oxbow_lambda.aws_lambda_event_source_mapping.this["sqs"]
}

moved {
  from = aws_iam_policy.this_lambda_permissions
  to   = aws_iam_policy.oxbow_lambda
}

moved {
  from = aws_sqs_queue.this_sqs
  to   = module.oxbow_queue[0].aws_sqs_queue.this
}

moved {
  from = aws_sqs_queue.this_DL
  to   = module.oxbow_queue[0].aws_sqs_queue.dlq
}

moved {
  from = aws_lambda_permission.this_lambda_allow_bucket_permissions
  to   = aws_lambda_permission.oxbow_from_s3
}

moved {
  from = aws_sns_topic_subscription.this_sns_sub
  to   = aws_sns_topic_subscription.oxbow
}

moved {
  from = aws_dynamodb_table.this_oxbow_locking
  to   = aws_dynamodb_table.oxbow_locking
}

moved {
  from = aws_glue_catalog_table.this_glue_table
  to   = aws_glue_catalog_table.oxbow
}

moved {
  from = aws_s3_bucket_notification.this_bucket_notification
  to   = aws_s3_bucket_notification.warehouse
}

################################################################################
# Group events
################################################################################

moved {
  from = aws_lambda_function.group_events_lambda
  to   = module.group_events_lambda[0].aws_lambda_function.this
}

moved {
  from = aws_lambda_event_source_mapping.group_events_lambda_sqs_trigger[0]
  to   = module.group_events_lambda[0].aws_lambda_event_source_mapping.this["sqs"]
}

moved {
  from = aws_sqs_queue.group_events_lambda_sqs
  to   = module.group_events_queue[0].aws_sqs_queue.this
}

moved {
  from = aws_sqs_queue.group_events_lambda_sqs_dlq
  to   = module.group_events_queue[0].aws_sqs_queue.dlq
}

moved {
  from = aws_sqs_queue.oxbow_lambda_fifo_sqs
  to   = module.oxbow_fifo_queue[0].aws_sqs_queue.this
}

moved {
  from = aws_sqs_queue.oxbow_lambda_fifo_sqs_dlq
  to   = module.oxbow_fifo_queue[0].aws_sqs_queue.dlq
}

################################################################################
# Auto tagging
################################################################################

moved {
  from = aws_lambda_function.auto_tagging
  to   = module.auto_tagging_lambda[0].aws_lambda_function.this
}

moved {
  from = aws_iam_role.auto_tagging_lambda
  to   = module.auto_tagging_lambda[0].aws_iam_role.lambda
}

moved {
  from = aws_lambda_event_source_mapping.auto_tagging[0]
  to   = module.auto_tagging_lambda[0].aws_lambda_event_source_mapping.this["sqs"]
}

moved {
  from = aws_iam_policy.auto_tagging_lambda
  to   = aws_iam_policy.auto_tagging
}

moved {
  from = aws_sqs_queue.auto_tagging
  to   = module.auto_tagging_queue[0].aws_sqs_queue.this
}

moved {
  from = aws_sqs_queue.auto_tagging_dl
  to   = module.auto_tagging_queue[0].aws_sqs_queue.dlq
}

################################################################################
# Glue create
################################################################################

moved {
  from = aws_lambda_function.glue_create_lambda
  to   = module.glue_create_lambda[0].aws_lambda_function.this
}

moved {
  from = aws_iam_role.glue_create
  to   = module.glue_create_lambda[0].aws_iam_role.lambda
}

moved {
  from = aws_lambda_event_source_mapping.glue_create[0]
  to   = module.glue_create_lambda[0].aws_lambda_event_source_mapping.this["sqs"]
}

moved {
  from = aws_iam_policy.glue_create_managed
  to   = aws_iam_policy.glue_create
}

moved {
  from = aws_sqs_queue.glue_create
  to   = module.glue_create_queue[0].aws_sqs_queue.this
}

moved {
  from = aws_sqs_queue.glue_create_dl
  to   = module.glue_create_queue[0].aws_sqs_queue.dlq
}

moved {
  from = aws_sqs_queue_redrive_allow_policy.terraform_queue_redrive_allow_policy
  to   = module.glue_create_queue[0].aws_sqs_queue_redrive_allow_policy.dlq
}

moved {
  from = aws_sns_topic_subscription.glue_create_sns_sub
  to   = aws_sns_topic_subscription.glue_create
}

################################################################################
# Glue sync
################################################################################

moved {
  from = aws_lambda_function.glue_sync_lambda
  to   = module.glue_sync_lambda[0].aws_lambda_function.this
}

moved {
  from = aws_iam_role.glue_sync
  to   = module.glue_sync_lambda[0].aws_iam_role.lambda
}

moved {
  from = aws_lambda_event_source_mapping.glue_sync[0]
  to   = module.glue_sync_lambda[0].aws_lambda_event_source_mapping.this["sqs"]
}

moved {
  from = aws_iam_policy.glue_sync_managed
  to   = aws_iam_policy.glue_sync
}

moved {
  from = aws_sqs_queue.glue_sync
  to   = module.glue_sync_queue[0].aws_sqs_queue.this
}

moved {
  from = aws_sqs_queue.glue_sync_dl
  to   = module.glue_sync_queue[0].aws_sqs_queue.dlq
}

moved {
  from = aws_sqs_queue_redrive_allow_policy.glue_syncredrive_allow_policy
  to   = module.glue_sync_queue[0].aws_sqs_queue_redrive_allow_policy.dlq
}

moved {
  from = aws_sns_topic_subscription.glue_sync_sns_sub
  to   = aws_sns_topic_subscription.glue_sync
}

################################################################################
# Monitoring
################################################################################

moved {
  from = datadog_monitor.dead_letters_monitor
  to   = datadog_monitor.dead_letters
}
