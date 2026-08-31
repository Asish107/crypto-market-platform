locals {
  # channel -> avro schema file. Adding a channel is a one-line change here.
  channels = {
    trades    = "trades.avsc"
    l2        = "l2.avsc"
    heartbeat = "heartbeat.avsc"
  }

  # Pub/Sub's native GCS sink cannot partition by a message field, so the lake
  # is partitioned by arrival hour only and product_id stays a column. See
  # docs/adr/0002. External tables hive-partition on dt/hour; product is a
  # clustering key in BigQuery instead.
  # Pub/Sub's filename grammar is far narrower than it looks. It requires ALL
  # SIX datetime matchers (YYYY MM DD hh mm ss), permits each exactly once, and
  # allows NO literal text beyond - _ : and /. So "hour=" cannot appear in the
  # datetime format at all.
  #
  # BigQuery hive partitioning, meanwhile, requires key=value directories. The
  # only free text available is filename_prefix, which is static - so the lake
  # gets exactly ONE hive level, and it has to be the useful one: dt.
  #
  #   trades/dt=2026-08-30/14_35_01_a1b2c3.avro
  #   \_____________________/\__________________/
  #     prefix + hive level          filename
  #
  # Hour therefore lives in the filename rather than a partition key. That
  # costs nothing real: every downstream model partitions by DAY, so hour-level
  # pruning was never going to be used. Pub/Sub appends its own unique id, so
  # concurrent flushes in the same second cannot collide.
  gcs_datetime_format = "YYYY-MM-DD/hh_mm_ss"
}

# ---------------------------------------------------------------------------
# Schemas. Registering these on the topic means a malformed publish is rejected
# at the broker, not discovered three layers downstream in a dbt test.
# ---------------------------------------------------------------------------
# The name embeds a hash of the definition. Pub/Sub schemas are IMMUTABLE, so
# a definition change means a NEW schema resource - and with a static name,
# create_before_destroy would collide with the schema it is replacing. Content
# addressing makes the replacement a clean create-then-swap-then-destroy, which
# is what lets a schema change be an ordinary reviewable diff rather than a
# manual detach-and-recreate.
resource "google_pubsub_schema" "this" {
  for_each = local.channels

  name       = "market-raw-${each.key}-${var.env}-${substr(md5(file("${var.schema_dir}/${each.value}")), 0, 8)}"
  project    = var.project_id
  type       = "AVRO"
  definition = file("${var.schema_dir}/${each.value}")

  lifecycle {
    # A schema is immutable in Pub/Sub; a change means a new schema resource,
    # which means the topic must be recreated. Force that to be deliberate.
    create_before_destroy = true
  }
}

resource "google_pubsub_topic" "raw" {
  for_each = local.channels

  name    = "market.raw.${each.key}"
  project = var.project_id
  labels  = var.labels

  # 7 days: long enough that a weekend outage of a subscriber loses nothing.
  message_retention_duration = "604800s"

  schema_settings {
    schema   = google_pubsub_schema.this[each.key].id
    encoding = "JSON"
  }

  depends_on = [google_pubsub_schema.this]
}

# One DLQ per channel. A subscription that cannot deliver must have somewhere
# to put the message that is not "drop it".
resource "google_pubsub_topic" "dlq" {
  for_each = local.channels

  name                       = "market.dlq.${each.key}"
  project                    = var.project_id
  labels                     = var.labels
  message_retention_duration = "604800s"
}

# Nothing consumes the DLQ automatically. This subscription exists so messages
# are retained and drainable by hand — see docs/runbook.md.
resource "google_pubsub_subscription" "dlq_hold" {
  for_each = local.channels

  name                       = "market.dlq.${each.key}.hold"
  project                    = var.project_id
  topic                      = google_pubsub_topic.dlq[each.key].id
  message_retention_duration = "604800s"
  labels                     = var.labels
  expiration_policy { ttl = "" } # never expire
}

# ---------------------------------------------------------------------------
# Native GCS sink -> the immutable lake. Zero compute: no Dataflow, no
# Cloud Run, nothing to page anyone about at 3am. This is the replay source.
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "gcs" {
  for_each = local.channels

  name    = "market.raw.${each.key}.gcs"
  project = var.project_id
  topic   = google_pubsub_topic.raw[each.key].id
  labels  = var.labels

  cloud_storage_config {
    bucket                   = var.raw_bucket
    filename_prefix          = "${each.key}/dt="
    filename_suffix          = ".avro"
    filename_datetime_format = local.gcs_datetime_format
    max_bytes                = var.gcs_flush_bytes
    max_duration             = var.gcs_flush_duration

    # Pub/Sub refuses Avro output + use_topic_schema on a JSON-encoded topic:
    # that combination requires BINARY encoding, which ADR 0006 rejected on
    # debuggability grounds.
    #
    # So the lake stores the ENVELOPE, not typed columns: message_id,
    # publish_time, attributes, and the message body as raw bytes. That is a
    # better property for a system of record than typed columns would be - the
    # lake holds exactly what the broker received, byte for byte, and cannot be
    # invalidated by a later schema change. Parsing is staging's job.
    #
    # Note the deliberate asymmetry with the BigQuery sink, which DOES use the
    # topic schema: BigQuery raw is a typed convenience cache, the lake is
    # fidelity. Different jobs, different tradeoffs.
    avro_config {
      use_topic_schema = false
      write_metadata   = true
    }
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq[each.key].id
    max_delivery_attempts = 10
  }

  depends_on = [
    google_storage_bucket_iam_member.gcs_sink_creator,
    google_storage_bucket_iam_member.gcs_sink_bucket_reader,
  ]
}

# ---------------------------------------------------------------------------
# Native BigQuery sink -> raw dataset. Also zero compute. The lake is the
# system of record; this table is the fast path so staging does not have to
# read Avro off GCS on every run.
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "bq" {
  for_each = local.channels

  name    = "market.raw.${each.key}.bq"
  project = var.project_id
  topic   = google_pubsub_topic.raw[each.key].id
  labels  = var.labels

  bigquery_config {
    table               = "${var.project_id}.${var.bq_raw_dataset}.${each.key}_stream"
    use_topic_schema    = true
    write_metadata      = true
    drop_unknown_fields = false # fail loudly rather than silently discard a new field
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq[each.key].id
    max_delivery_attempts = 10
  }

  depends_on = [
    google_project_iam_member.bq_sink_editor,
    google_project_iam_member.bq_sink_metadata,
  ]
}

# ---------------------------------------------------------------------------
# IAM. Native sinks run as the per-project Pub/Sub service agent, which needs
# explicit grants — this is the single most common reason a native sink
# silently delivers nothing.
# ---------------------------------------------------------------------------
data "google_project" "this" {
  project_id = var.project_id
}

# The Pub/Sub service agent is created LAZILY by Google - enabling the API is
# not enough. Granting IAM to it before it exists fails with "Service account
# does not exist", which then succeeds on a retry once Google has quietly
# provisioned it. That is a coin flip, not a deployment. This resource forces
# the agent into existence so a first apply into a fresh project is
# deterministic.
resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"
}

locals {
  pubsub_sa = "serviceAccount:${google_project_service_identity.pubsub.email}"
}

resource "google_storage_bucket_iam_member" "gcs_sink_creator" {
  bucket = var.raw_bucket
  role   = "roles/storage.objectCreator"
  member = local.pubsub_sa
}

# legacyBucketReader lets the sink read bucket metadata (it checks the bucket
# exists and is writable before every flush). It is a BUCKET-level role - GCP
# rejects it at project level - and scoping it to the one bucket is what we
# wanted anyway.
resource "google_storage_bucket_iam_member" "gcs_sink_bucket_reader" {
  bucket = var.raw_bucket
  role   = "roles/storage.legacyBucketReader"
  member = local.pubsub_sa
}

resource "google_project_iam_member" "bq_sink_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = local.pubsub_sa
}

resource "google_project_iam_member" "bq_sink_metadata" {
  project = var.project_id
  role    = "roles/bigquery.metadataViewer"
  member  = local.pubsub_sa
}

# The ingest SA gets publisher on exactly these three topics. Not project-wide
# publisher, and certainly not editor.
resource "google_pubsub_topic_iam_member" "ingest_publisher" {
  for_each = local.channels

  project = var.project_id
  topic   = google_pubsub_topic.raw[each.key].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${var.publisher_sa_email}"
}


# ---------------------------------------------------------------------------
# Streaming subscription for the Dataflow reconciliation job (§6).
#
# A SEPARATE subscription, not a shared one: Pub/Sub delivers to each
# subscription independently, so a burst-run streaming job cannot starve or
# duplicate what the native sinks receive. Starting and stopping Dataflow has
# no effect on the always-on path.
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "streaming_trades" {
  name    = "market.raw.trades.streaming"
  project = var.project_id
  topic   = google_pubsub_topic.raw["trades"].id
  labels  = var.labels

  # Short retention: this subscription is for burst runs. Retaining a week of
  # backlog for a job that runs for an hour would mean the first thing it does
  # on startup is replay days of stale trades into current windows - which
  # would look exactly like catastrophic lateness.
  message_retention_duration = "3600s"
  ack_deadline_seconds       = 60

  expiration_policy { ttl = "" }
}
