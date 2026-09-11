locals {
  # Mirrors how the sqs module derives a FIFO name, so the monitor's queuename
  # tag matches the queue whether or not the caller already wrote the suffix.
  fifo_dlq_name = "${trimsuffix(var.sqs_fifo_DL_queue_name, ".fifo")}.fifo"

  dead_letter_queue_names = [
    for name in compact([
      local.group_events ? local.fifo_dlq_name : var.sqs_queue_name_dl,
      local.group_events ? var.sqs_group_DL_queue_name : "",
      var.enable_glue_create ? var.glue_create_config.sqs_queue_name_dl : "",
      var.enable_glue_sync ? var.glue_sync_config.sqs_queue_name_dl : "",
      var.enable_auto_tagging ? "${local.auto_tagging_queue_name}-dl" : "",
    ]) : lower(name)
  ]

  monitor_query_conditions = var.monitoring_query_conditions != "" ? ", ${var.monitoring_query_conditions}" : ""
}

resource "datadog_monitor" "dead_letters" {
  for_each = var.enabled_dead_letters_monitoring ? toset(local.dead_letter_queue_names) : toset([])

  type = "metric alert"
  name = "${each.key}-monitor"
  message = templatefile("${path.module}/templates/dl_monitor.tmpl", {
    dl_alert_message        = var.dl_alert_message
    dead_letters_queue_name = each.key
    notify                  = join(", ", var.dl_alert_recipients)
  })
  query = "avg(last_1h):avg:aws.sqs.approximate_number_of_messages_visible{queuename:${each.key}${local.monitor_query_conditions}} > ${var.dl_critical}"

  monitor_thresholds {
    warning  = var.dl_warning
    critical = var.dl_critical
    ok       = var.dl_ok
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitoring

  lifecycle {
    precondition {
      condition     = var.dl_critical != null && var.dl_critical != ""
      error_message = "dl_critical must be set when enabled_dead_letters_monitoring is true; it is the monitor's alert threshold."
    }
  }
}
