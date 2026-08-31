# ---------------------------------------------------------------------------
# Log-based metrics.
#
# The consumer emits structured JSON to stdout, which Cloud Logging parses into
# fields. Extracting counters from those fields costs nothing and needs no
# extra code path in the consumer - the log line IS the metric.
# ---------------------------------------------------------------------------

resource "google_logging_metric" "trade_gaps" {
  project     = var.project_id
  name        = "market_trade_gaps_${var.env}"
  description = "Breaks in trade_id continuity - real, counted data loss."
  filter      = <<-EOT
    jsonPayload.logger="consumer.ws_client"
    jsonPayload.message="trade gap"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }

  # Counts gap EVENTS, not trades lost. A value extractor would give the
  # latter but requires a DISTRIBUTION metric, and distributions cannot be
  # summed in an alert condition without picking a percentile - which is the
  # wrong shape for "how many trades did we lose".
  #
  # The exact count lives in marts.fct_data_quality, which is a better home
  # anyway: it is queryable, historical, and joinable to the data it describes.
  # This metric exists to fire the alert; that mart exists to answer the
  # question the alert raises.
}

resource "google_logging_metric" "crossed_books" {
  project     = var.project_id
  name        = "market_crossed_books_${var.env}"
  description = "Bid >= ask. Never a market condition; always a bug."
  filter      = <<-EOT
    jsonPayload.logger="consumer.ws_client"
    jsonPayload.message="crossed book"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "reconnects" {
  project     = var.project_id
  name        = "market_reconnects_${var.env}"
  description = "WebSocket reconnects. A trickle is normal; a storm is not."
  filter      = <<-EOT
    jsonPayload.logger="consumer.ws_client"
    jsonPayload.message="connection lost"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "publish_failures" {
  project     = var.project_id
  name        = "market_publish_failures_${var.env}"
  description = "Failed publishes. With ordering keys, one failure stalls a whole product."
  filter      = <<-EOT
    jsonPayload.logger="consumer.publisher"
    jsonPayload.message="publish failed"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

# ---------------------------------------------------------------------------
# Alert policies.
#
# Every one of these has a documented response in docs/runbook.md. An alert
# without a runbook entry is a notification, not an alert.
# ---------------------------------------------------------------------------

# THE alert. Everything else measures quality; this one says the platform has
# stopped being a platform.
resource "google_monitoring_alert_policy" "feed_silent" {
  project      = var.project_id
  display_name = "PAGE: market feed silent (${var.env})"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    content   = <<-EOT
      No messages published to market.raw.trades for 5 minutes.

      Runbook: docs/runbook.md, "The feed is silent". Check in order:
      1. Is the VM alive?      gcloud compute instances describe market-ingest-${var.env} --zone us-central1-a
      2. Is it reconnect-looping?  check the `error_type` field in its logs
      3. Is Coinbase down?     https://status.coinbase.com
      4. Is it connected but stalled? look for "feed stalled" - the heartbeat
         watchdog firing means detection worked
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "no trades published for 5 minutes"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type = \"pubsub_topic\"",
        "resource.labels.topic_id = \"market.raw.trades\"",
        "metric.type = \"pubsub.googleapis.com/topic/send_request_count\"",
      ])
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }

      # Without this, a feed that stops publishing produces NO data points,
      # and a condition with no data never fires - the classic silent-alert
      # failure, where the thing that breaks the metric also disables its own
      # alarm.
      evaluation_missing_data = "EVALUATION_MISSING_DATA_ACTIVE"
    }
  }

  notification_channels = [var.notification_channel_id]
  alert_strategy { auto_close = "3600s" }
}

resource "google_monitoring_alert_policy" "crossed_book" {
  project      = var.project_id
  display_name = "PAGE: crossed book detected (${var.env})"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    content   = "A crossed book means the order book reconstruction is broken and every liquidity figure downstream is suspect. Any occurrence is worth waking someone. Runbook: docs/runbook.md."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "any crossed book"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.crossed_books.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [var.notification_channel_id]
}

resource "google_monitoring_alert_policy" "trade_gaps" {
  project      = var.project_id
  display_name = "WARN: trade gap rate elevated (${var.env})"
  combiner     = "OR"
  severity     = "WARNING"

  documentation {
    content   = "Trades were lost. trade_id is contiguous, so the missing range is known exactly and the Coinbase REST endpoint can backfill it precisely. Runbook: docs/runbook.md, 'Trade gaps spiked'."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "more than 5 gap events in an hour"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.trade_gaps.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"
      aggregations {
        alignment_period   = "3600s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [var.notification_channel_id]
}

resource "google_monitoring_alert_policy" "publish_failures" {
  project      = var.project_id
  display_name = "PAGE: publishes failing (${var.env})"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    content   = "With ordering keys enabled, one failed publish stalls that product's ENTIRE stream until the key is resumed. Find the FIRST error - the rest are consequences. Runbook: docs/runbook.md, 'Every publish for a product suddenly fails'."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "any publish failure"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.publish_failures.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [var.notification_channel_id]
}

resource "google_monitoring_alert_policy" "reconnect_storm" {
  project      = var.project_id
  display_name = "WARN: reconnect storm (${var.env})"
  combiner     = "OR"
  severity     = "WARNING"

  documentation {
    content   = "More than 10 reconnects in 15 minutes. The consumer recovers from each one, but a storm means data is being lost in the gaps and the book is repeatedly invalidated."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "more than 10 reconnects in 15 minutes"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"logging.googleapis.com/user/${google_logging_metric.reconnects.name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 10
      duration        = "0s"
      aggregations {
        alignment_period   = "900s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [var.notification_channel_id]
}

# The VM itself. A dead consumer is caught by feed_silent within 5 minutes, but
# this names the cause directly instead of leaving someone to work it out.
resource "google_monitoring_alert_policy" "ingest_vm_down" {
  project      = var.project_id
  display_name = "PAGE: ingest VM not running (${var.env})"
  combiner     = "OR"
  severity     = "CRITICAL"

  documentation {
    content   = "The consumer VM is not reporting. It is stateless - recreating it costs one reconnect, not data. `terraform apply` rebuilds it."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "no CPU metrics from the ingest VM"
    condition_absent {
      filter = join(" AND ", [
        "resource.type = \"gce_instance\"",
        "metric.type = \"compute.googleapis.com/instance/cpu/utilization\"",
      ])
      duration = "600s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [var.notification_channel_id]
}
