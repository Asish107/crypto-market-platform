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
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}
