output "ingest_sa_email" { value = google_service_account.ingest.email }
output "dbt_sa_email" { value = google_service_account.dbt.email }
output "deployer_sa_email" { value = google_service_account.deployer.email }
output "dataflow_sa_email" { value = google_service_account.dataflow.email }
