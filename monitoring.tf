locals {
  enable_dead_letters_monitoring = var.enabled_dead_letters_monitoring
  dl_warning                     = var.dl_warning
  dl_critical                    = var.dl_critical

}

resource "datadog_monitor" "dead_letters_monitor" {
  count = local.enable_dead_letters_monitoring ? 1 : 0

  type = "metric alert"
  name = "${var.sqs_queue_name_dl}-monitor"
  message = templatefile("${path.module}/templates/dl_monitor.tmpl", {
    dead_letters_queue_name = local.enable_group_events ? var.sqs_fifo_DL_queue_name : var.sqs_queue_name_dl
    notify                  = join(", ", var.dl_alert_recipients)
  })
  query = "avg(last_1h):avg:aws.sqs.approximate_number_of_messages_visible{queuename:${var.sqs_queue_name_dl}} > ${var.dl_critical}"

  monitor_thresholds {
    warning           = local.dl_warning
    warning_recovery  = local.dl_warning - 1
    critical          = local.dl_critical
    critical_recovery = local.dl_critical - 1
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitoring
}

resource "datadog_monitor" "dead_letters_monitor_glue_create" {
  count = local.enable_dead_letters_monitoring && local.enable_glue_create ? 1 : 0

  type = "metric alert"
  name = "${var.glue_create_config.sqs_queue_name_dl}-monitor"
  message = templatefile("${path.module}/templates/dl_monitor.tmpl", {
    dead_letters_queue_name = var.glue_create_config.sqs_queue_name_dl
    notify                  = join(", ", var.dl_alert_recipients)
  })
  query = "avg(last_1h):avg:aws.sqs.approximate_number_of_messages_visible{queuename:${var.glue_create_config.sqs_queue_name_dl}} > ${var.dl_critical}"

  monitor_thresholds {
    warning           = local.dl_warning
    warning_recovery  = local.dl_warning - 1
    critical          = local.dl_critical
    critical_recovery = local.dl_critical - 1
  }

  notify_no_data    = false
  renotify_interval = 60
  tags              = var.tags_monitoring
}
