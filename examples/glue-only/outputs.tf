output "enabled_stages" {
  description = "Only the glue stages and monitoring are on"
  value       = module.oxbow.enabled_stages
}

output "dead_letter_queue_arns" {
  description = "Dead letter queues for the two glue stages"
  value       = module.oxbow.dead_letter_queue_arns
}
