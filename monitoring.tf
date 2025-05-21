locals {
  base_dlq_name = local.enable_group_events ? lower("${var.sqs_fifo_DL_queue_name}.fifo") : lower(var.sqs_queue_name_dl)
  dlq_to_monitor = [
    local.base_dlq_name,
    local.enable_group_events ? lower(var.sqs_group_DL_queue_name) : local.base_dlq_name,
    var.enable_glue_create ? lower(var.glue_create_config.sqs_queue_name_dl) : local.base_dlq_name,
    var.enable_glue_sync ? lower(var.glue_sync_config.sqs_queue_name_dl) : local.base_dlq_name,
  ]
  additional_query_conditions = length(var.monitoring_query_conditions) > 0 ? ", ${var.monitoring_query_conditions}" : ""
}

resource "datadog_monitor" "dead_letters_monitor" {
  for_each = var.enabled_dead_letters_monitoring ? toset(local.dlq_to_monitor) : []

  type = "metric alert"
  name = "${each.key}-monitor"
  message = templatefile("${path.module}/templates/dl_monitor.tmpl", {
    dl_alert_message        = var.dl_alert_message
    dead_letters_queue_name = each.key
    notify                  = join(", ", var.dl_alert_recipients)
  })
  query = "avg(last_1h):avg:aws.sqs.approximate_number_of_messages_visible{queuename:${each.key}${local.additional_query_conditions}} > ${var.dl_critical}"

  monitor_thresholds {
    warning  = var.dl_warning
    critical = var.dl_critical
    ok       = var.dl_ok
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitoring
}
