output "tfstate_bucket" {
  value       = google_storage_bucket.tfstate.name
  description = "Pass to terraform init: -backend-config=bucket=<this>"
}

output "workload_identity_provider" {
  value       = google_iam_workload_identity_pool_provider.github.name
  description = "Set as the GitHub repo variable WIF_PROVIDER."
}
