output "raw_bucket" { value = module.storage.raw_bucket }
output "topics" { value = module.pubsub.topic_names }
output "gcs_subscriptions" { value = module.pubsub.gcs_subscriptions }
output "bq_subscriptions" { value = module.pubsub.bq_subscriptions }
output "datasets" { value = module.bigquery.dataset_ids }
output "external_tables" { value = module.bigquery.external_tables }
output "ingest_sa" { value = module.iam.ingest_sa_email }
output "dbt_sa" { value = module.iam.dbt_sa_email }

output "image_repository" { value = module.ingest_vm.repository_url }
output "ingest_instance" { value = module.ingest_vm.instance_name }

output "dashboard" { value = module.observability.dashboard_id }
output "alert_policies" { value = module.observability.alert_policy_names }
