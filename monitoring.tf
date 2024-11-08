locals {
  enable_dead_letters_monitoring = var.enabled_dead_letters_monitoring
  dl_warning                     = var.dl_warning
  dl_critical                    = var.dl_critical
  dlq_to_monitor = [
    local.enable_group_events ? var.sqs_fifo_DL_queue_name : var.sqs_queue_name_dl,
    var.enable_glue_create ? var.glue_create_config.sqs_queue_name_dl : "",
    var.enable_glue_sync ? var.glue_sync_config.sqs_queue_name_dl : "",
  ]
}

resource "datadog_monitor" "dead_letters_monitor" {
  for_each = local.enable_dead_letters_monitoring ? toset(local.dlq_to_monitor) : []

  type = "metric alert"
  name = "${each.key}-monitor"
  message = templatefile("${path.module}/templates/dl_monitor.tmpl", {
    dl_alert_message        = var.dl_alert_message
    dead_letters_queue_name = each.key
    notify                  = join(", ", var.dl_alert_recipients)
  })
  query = "avg(last_1h):avg:aws.sqs.approximate_number_of_messages_visible{queuename:${each.key}} > ${var.dl_critical}"

  monitor_thresholds {
    warning  = local.dl_warning
    critical = local.dl_critical
    ok       = local.dl_ok
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitoring
}
