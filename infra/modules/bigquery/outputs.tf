output "dataset_ids" {
  value = { for k, d in google_bigquery_dataset.this : k => d.dataset_id }
}

output "raw_dataset" {
  value = google_bigquery_dataset.this["raw"].dataset_id
}

output "raw_tables" {
  value = { for k, t in google_bigquery_table.raw_stream : k => "${var.project_id}.${t.dataset_id}.${t.table_id}" }
}

output "external_tables" {
  value = { for k, t in google_bigquery_table.raw_external : k => "${var.project_id}.${t.dataset_id}.${t.table_id}" }
}
