output "enabled_stages" {
  description = "Which stages this deployment switched on"
  value       = module.oxbow.enabled_stages
}

output "dead_letter_queue_arns" {
  description = "Every dead letter queue, one monitor each"
  value       = module.oxbow.dead_letter_queue_arns
}

output "dead_letters_monitor_ids" {
  description = "Datadog monitors created for those queues"
  value       = module.oxbow.dead_letters_monitor_ids
}
