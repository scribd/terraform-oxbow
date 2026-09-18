resource "aws_sns_topic_subscription" "oxbow" {
  count = local.enabled.sns_delivery && local.enabled.oxbow ? 1 : 0

  topic_arn           = local.sns_topic_arn
  protocol            = "sqs"
  endpoint            = local.ingest_queue_arn
  filter_policy       = var.sns_delivery.filter_policy
  filter_policy_scope = var.sns_delivery.filter_policy_scope

  depends_on = [module.oxbow_queue, module.group_events_queue]
}
