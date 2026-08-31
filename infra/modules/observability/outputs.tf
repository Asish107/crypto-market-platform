output "dashboard_id" { value = google_monitoring_dashboard.market.id }

output "alert_policy_names" {
  value = [
    google_monitoring_alert_policy.feed_silent.display_name,
    google_monitoring_alert_policy.crossed_book.display_name,
    google_monitoring_alert_policy.trade_gaps.display_name,
    google_monitoring_alert_policy.publish_failures.display_name,
    google_monitoring_alert_policy.reconnect_storm.display_name,
    google_monitoring_alert_policy.ingest_vm_down.display_name,
  ]
}
