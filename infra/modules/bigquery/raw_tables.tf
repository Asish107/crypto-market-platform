# ---------------------------------------------------------------------------
# The BigQuery subscription writes into these. The columns must match the topic
# Avro schema exactly (plus the metadata columns, because write_metadata=true),
# or the subscription goes permanently unhealthy with no data loss but no
# delivery either. Keeping the DDL in Terraform next to the .avsc is how you
# stop those two drifting apart.
# ---------------------------------------------------------------------------
locals {
  # Written by Pub/Sub itself when write_metadata = true.
  metadata_columns = [
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "NULLABLE" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "attributes", type = "JSON", mode = "NULLABLE" },
  ]

  # What Pub/Sub's native GCS sink writes when write_metadata = true and
  # use_topic_schema = false: the envelope, with the message body as bytes.
  lake_envelope = [
    { name = "subscription_name", type = "STRING", mode = "NULLABLE" },
    { name = "message_id", type = "STRING", mode = "NULLABLE" },
    { name = "publish_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "data", type = "BYTES", mode = "NULLABLE" },
    { name = "attributes", type = "STRING", mode = "NULLABLE" },
  ]

  raw_schemas = {
    trades = [
      { name = "sequence", type = "INT64", mode = "REQUIRED" },
      { name = "product_id", type = "STRING", mode = "REQUIRED" },
      { name = "trade_id", type = "INT64", mode = "REQUIRED" },
      { name = "price", type = "STRING", mode = "REQUIRED" },
      { name = "size", type = "STRING", mode = "REQUIRED" },
      { name = "side", type = "STRING", mode = "REQUIRED" },
      { name = "maker_order_id", type = "STRING", mode = "NULLABLE" }, # "" when absent
      { name = "taker_order_id", type = "STRING", mode = "NULLABLE" },
      { name = "event_time", type = "STRING", mode = "REQUIRED" },
      { name = "ingest_time", type = "STRING", mode = "REQUIRED" },
    ]
    l2 = [
      { name = "sequence", type = "INT64", mode = "REQUIRED" },
      { name = "product_id", type = "STRING", mode = "REQUIRED" },
      { name = "event_type", type = "STRING", mode = "REQUIRED" },
      { name = "payload", type = "STRING", mode = "REQUIRED" },
      { name = "event_time", type = "STRING", mode = "REQUIRED" },
      { name = "ingest_time", type = "STRING", mode = "REQUIRED" },
    ]
    heartbeat = [
      { name = "sequence", type = "INT64", mode = "REQUIRED" },
      { name = "product_id", type = "STRING", mode = "REQUIRED" },
      { name = "last_trade_id", type = "INT64", mode = "REQUIRED" },
      { name = "event_time", type = "STRING", mode = "REQUIRED" },
      { name = "ingest_time", type = "STRING", mode = "REQUIRED" },
    ]
  }
}

resource "google_bigquery_table" "raw_stream" {
  for_each = local.raw_schemas

  dataset_id          = google_bigquery_dataset.this["raw"].dataset_id
  project             = var.project_id
  table_id            = "${each.key}_stream"
  deletion_protection = false
  labels              = var.labels

  description = "Native Pub/Sub BigQuery subscription sink for market.raw.${each.key}. Do not write to this table by any other means."

  # Forcing a partition filter is a cost guardrail, not pedantry: it makes an
  # accidental full-table scan fail instead of quietly billing for one.
  require_partition_filter = true

  time_partitioning {
    type          = "DAY"
    field         = null # _PARTITIONTIME: arrival time, since event_time is still a string here
    expiration_ms = var.raw_table_expiration_days * 24 * 3600 * 1000
  }

  clustering = ["product_id"]

  schema = jsonencode(concat(each.value, local.metadata_columns))
}
