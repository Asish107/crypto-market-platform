output "raw_bucket" { value = google_storage_bucket.raw.name }
output "raw_bucket_url" { value = "gs://${google_storage_bucket.raw.name}" }
output "quarantine_bucket" { value = google_storage_bucket.quarantine.name }
output "artifacts_bucket" { value = google_storage_bucket.artifacts.name }
