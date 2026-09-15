output "ingest_queue_arn" {
  description = "Queue subscribed to the topic"
  value       = module.oxbow.ingest_queue_arn
}

output "enabled_stages" {
  description = "Which stages this deployment switched on"
  value       = module.oxbow.enabled_stages
}
