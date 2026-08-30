# ---------------------------------------------------------------------------
# dev: one product, short retention, small everything. Its purpose is to make
# `terraform destroy && terraform apply` cheap enough that you actually do it.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }

  backend "gcs" {
    # bucket comes from -backend-config; see Makefile
    prefix = "crypto-market-platform/dev"
  }
}

# billing_project + user_project_override are required for APIs that bill a
# consumer project rather than the resource's project - billingbudgets is the
# one that bites here. Without them, a human's Application Default Credentials
# send requests with no quota project and Google rejects them against its own
# default client project (764086051850), which reads as a baffling
# SERVICE_DISABLED error for a service you never touched.
provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

locals {
  env = "dev"

  labels = {
    project = "crypto-market-platform"
    env     = local.env
    owner   = "data-platform"
    managed = "terraform"
  }
}

module "iam" {
  source     = "../../modules/iam"
  project_id = var.project_id
  env        = local.env
}

module "storage" {
  source              = "../../modules/storage"
  project_id          = var.project_id
  region              = var.region
  env                 = local.env
  raw_retention_days  = 7
  nearline_after_days = 30
  coldline_after_days = 90
  labels              = local.labels
}

module "bigquery" {
  source                    = "../../modules/bigquery"
  project_id                = var.project_id
  region                    = var.region
  env                       = local.env
  raw_bucket                = module.storage.raw_bucket
  raw_table_expiration_days = 14
  dbt_sa_email              = module.iam.dbt_sa_email
  labels                    = local.labels
}

module "pubsub" {
  source             = "../../modules/pubsub"
  project_id         = var.project_id
  region             = var.region
  env                = local.env
  schema_dir         = "${path.root}/../../../schemas"
  raw_bucket         = module.storage.raw_bucket
  bq_raw_dataset     = module.bigquery.raw_dataset
  publisher_sa_email = module.iam.ingest_sa_email
  gcs_flush_duration = "300s"
  labels             = local.labels

  # The raw tables must exist before the BQ subscription is created, or the
  # subscription is born unhealthy.
  depends_on = [module.bigquery]
}

module "ingest_vm" {
  source                = "../../modules/ingest_vm"
  project_id            = var.project_id
  region                = var.region
  zone                  = var.zone
  env                   = local.env
  products              = var.products
  service_account_email = module.iam.ingest_sa_email
  labels                = local.labels

  # Flipped to true by CI once an image exists at a SHA tag. Until then the
  # Artifact Registry repo is created and the VM is not, so `terraform apply`
  # from zero never produces a VM crash-looping on a missing image.
  enabled = var.ingest_vm_enabled
  image   = var.ingest_image
}

module "budget" {
  source             = "../../modules/budget"
  project_id         = var.project_id
  billing_account    = var.billing_account
  env                = local.env
  monthly_budget_usd = 25
  alert_email        = var.alert_email
  deployer_sa_email  = module.iam.deployer_sa_email
}
