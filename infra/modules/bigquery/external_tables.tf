# ---------------------------------------------------------------------------
# The replay path. Everything downstream must be reconstructible from these
# tables alone — that is the property the recovery drill proves.
#
# The lake is partitioned by arrival DAY only - Pub/Sub's filename grammar
# allows exactly one key=value level (see modules/pubsub/main.tf) - and
# product_id lives in the row rather than the path. Product filtering uses
# BigQuery clustering instead, which prunes just as well. See docs/adr/0002.
# ---------------------------------------------------------------------------
resource "google_bigquery_table" "raw_external" {
  for_each = toset(["trades", "l2", "heartbeat"])

  dataset_id          = google_bigquery_dataset.this["raw_external"].dataset_id
  project             = var.project_id
  table_id            = "${each.key}_lake"
  deletion_protection = false
  labels              = var.labels

  description = "External table over gs://${var.raw_bucket}/${each.key}/. Immutable replay source."

  external_data_configuration {
    autodetect    = false
    source_format = "AVRO"
    source_uris   = ["gs://${var.raw_bucket}/${each.key}/*"]

    # An external table with no explicit schema asks BigQuery to infer one by
    # reading the files. On a fresh stack there are no files, so creation fails
    # with "matched no files" - the table cannot exist until data exists, and
    # data cannot land until the stack exists. Declaring the schema breaks that
    # circle: the table is created from the contract, not from a sample.
    #
    # The GCS sink writes the Pub/Sub ENVELOPE, not the topic schema (see
    # modules/pubsub/main.tf): the message body arrives as raw bytes in `data`,
    # which staging parses with JSON functions. The hive partition key dt is
    # appended by BigQuery and must NOT be listed here.
    #
    # UNVERIFIED against a real file until data lands - there are no files yet,
    # so BigQuery accepts this schema without checking it. `make smoke` in
    # Phase 2 is what confirms the field names and types actually match.
    schema = jsonencode(local.lake_envelope)

    hive_partitioning_options {
      mode                     = "CUSTOM"
      source_uri_prefix        = "gs://${var.raw_bucket}/${each.key}/{dt:DATE}"
      require_partition_filter = true
    }

    avro_options {
      use_avro_logical_types = true
    }
  }
}
