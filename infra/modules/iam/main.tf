# ---------------------------------------------------------------------------
# Least privilege, stated as code. Every SA here has the narrowest role set
# that lets it do its one job. There is no roles/editor in this repository and
# adding one should fail review.
#
# Resource-scoped grants (publish to *these three topics*, write to *these
# datasets*) live in the modules that own those resources, not here.
# ---------------------------------------------------------------------------

# The ingest VM. Publishes to Pub/Sub, writes custom metrics, writes logs.
# It cannot read BigQuery, cannot touch GCS, cannot start VMs.
resource "google_service_account" "ingest" {
  account_id   = "market-ingest-${var.env}"
  project      = var.project_id
  display_name = "Market data WS consumer (${var.env})"
  description  = "Publishes Coinbase feed messages to market.raw.*. Publish + telemetry only."
}

resource "google_project_iam_member" "ingest" {
  for_each = toset([
    "roles/monitoring.metricWriter",
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

# dbt / transformation. Runs queries, writes to the modelled datasets.
resource "google_service_account" "dbt" {
  account_id   = "market-dbt-${var.env}"
  project      = var.project_id
  display_name = "dbt transformation runner (${var.env})"
}

resource "google_project_iam_member" "dbt" {
  for_each = toset([
    "roles/bigquery.jobUser", # run queries; dataset-level write grants are in the bigquery module
    "roles/logging.logWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dbt.email}"
}

# CI/CD deployer, impersonated from GitHub Actions via Workload Identity
# Federation. No JSON key exists for this account, anywhere.
resource "google_service_account" "deployer" {
  account_id   = "market-deployer-${var.env}"
  project      = var.project_id
  display_name = "GitHub Actions deployer (${var.env})"
  description  = "Assumed via Workload Identity Federation. Never issue a key for this account."
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/storage.admin",
    "roles/pubsub.admin",
    "roles/bigquery.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/monitoring.editor",
    "roles/compute.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/artifactregistry.admin",
    # Log-based metrics are configured through the Logging API, not the
    # Monitoring one - monitoring.editor does not reach them.
    "roles/logging.configWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}


# Dataflow workers for the streaming reconciliation job (§6). Kept separate
# from the dbt SA: this one needs to run compute, read a subscription and
# write to GCS, none of which dbt has any business doing.
resource "google_service_account" "dataflow" {
  account_id   = "market-dataflow-${var.env}"
  project      = var.project_id
  display_name = "Dataflow streaming worker (${var.env})"
  description  = "Runs the burst streaming-bars job. Idle except during reconciliation runs."
}

resource "google_project_iam_member" "dataflow" {
  for_each = toset([
    "roles/dataflow.worker",
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/pubsub.subscriber",
    "roles/pubsub.viewer",
    "roles/storage.objectAdmin",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}


# Dataflow runs workers AS the account above, which means the Dataflow service
# agent must be allowed to impersonate it. Without this the job fails at
# submit with "the Dataflow service agent cannot access the worker service
# account" - the same lazily-created-service-agent pattern as Pub/Sub in §2.
resource "google_project_service_identity" "dataflow" {
  provider = google-beta
  project  = var.project_id
  service  = "dataflow.googleapis.com"
}

resource "google_service_account_iam_member" "dataflow_agent_can_use_worker" {
  service_account_id = google_service_account.dataflow.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_project_service_identity.dataflow.email}"
}

resource "google_project_iam_member" "dataflow_service_agent" {
  project = var.project_id
  role    = "roles/dataflow.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.dataflow.email}"
}
