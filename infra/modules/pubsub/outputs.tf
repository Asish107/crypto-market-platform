output "topic_ids" {
  value = { for k, t in google_pubsub_topic.raw : k => t.id }
}

output "topic_names" {
  value = { for k, t in google_pubsub_topic.raw : k => t.name }
}

output "dlq_topic_names" {
  value = { for k, t in google_pubsub_topic.dlq : k => t.name }
}

output "gcs_subscriptions" {
  value = { for k, s in google_pubsub_subscription.gcs : k => s.name }
}

output "bq_subscriptions" {
  value = { for k, s in google_pubsub_subscription.bq : k => s.name }
}

output "streaming_subscription" {
  value = google_pubsub_subscription.streaming_trades.id
}
