locals {
  dead_letter_queue_names = [
    for name in compact([
      local.enabled.group_events ? local.fifo_dlq_name : (local.oxbow_standard_queue ? var.oxbow.dl_queue_name : ""),
      local.enabled.group_events ? var.group_events.dl_queue_name : "",
      local.enabled.auto_tagging ? local.auto_tagging_dlq_name : "",
      local.enabled.glue_create ? var.glue_create.sqs_queue_name_dl : "",
      local.enabled.glue_sync ? var.glue_sync.sqs_queue_name_dl : "",
    ]) : lower(name)
  ]

  monitor_query_conditions = (
    local.enabled.dl_monitoring && var.dead_letter_monitoring.query_conditions != ""
    ? ", ${var.dead_letter_monitoring.query_conditions}"
    : ""
  )
}

resource "datadog_monitor" "dead_letters" {
  for_each = local.enabled.dl_monitoring ? toset(local.dead_letter_queue_names) : toset([])

  type = "metric alert"
  name = "${each.key}-monitor"
  message = templatefile("${path.module}/templates/dl_monitor.tmpl", {
    dl_alert_message        = var.dead_letter_monitoring.alert_message
    dead_letters_queue_name = each.key
    notify                  = join(", ", var.dead_letter_monitoring.alert_recipients)
  })
  query = "avg(last_1h):avg:aws.sqs.approximate_number_of_messages_visible{queuename:${each.key}${local.monitor_query_conditions}} > ${var.dead_letter_monitoring.critical}"

  monitor_thresholds {
    warning  = var.dead_letter_monitoring.warning
    critical = var.dead_letter_monitoring.critical
    ok       = var.dead_letter_monitoring.ok
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.dead_letter_monitoring.tags
}
