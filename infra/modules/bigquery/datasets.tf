locals {
  datasets = {
    raw          = "Native Pub/Sub landing. Append-only, never edited, never backfilled by hand."
    raw_external = "External tables over the GCS lake. This is the replay source of truth."
    staging      = "Cast, renamed, deduped. dbt-managed."
    intermediate = "Reusable logic between staging and marts. dbt-managed."
    marts        = "Contract-enforced business facts. dbt-managed."
    elementary   = "dbt test results and anomaly history."
    ci           = "Ephemeral CI datasets. 24h table TTL."
    curated      = "Streaming outputs. Written by Dataflow, read by the reconciliation model."
  }
}

resource "google_bigquery_dataset" "this" {
  for_each = local.datasets

  dataset_id    = each.key
  project       = var.project_id
  location      = var.region
  description   = each.value
  labels        = var.labels
  friendly_name = each.key

  default_table_expiration_ms = each.key == "ci" ? 24 * 3600 * 1000 : null

  # `raw` is deliberately not delete-protected in dev: it is rebuildable from
  # the lake, and terraform destroy must actually work end to end.
  delete_contents_on_destroy = var.env == "dev"
}

# dbt writes to staging/intermediate/marts/elementary and reads everything else.
resource "google_bigquery_dataset_iam_member" "dbt_editor" {
  for_each = toset(["staging", "intermediate", "marts", "elementary", "ci", "curated"])

  project    = var.project_id
  dataset_id = google_bigquery_dataset.this[each.key].dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${var.dbt_sa_email}"
}

resource "google_bigquery_dataset_iam_member" "dbt_reader" {
  for_each = toset(["raw", "raw_external"])

  project    = var.project_id
  dataset_id = google_bigquery_dataset.this[each.key].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${var.dbt_sa_email}"
}
