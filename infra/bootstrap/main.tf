# ---------------------------------------------------------------------------
# Bootstrap. Run ONCE, from a laptop, with LOCAL state, before anything else.
# It creates the two things that cannot be created by the thing that needs
# them: the remote state bucket, and the Workload Identity Federation pool
# that lets GitHub Actions authenticate without a service account key.
#
#   cd infra/bootstrap
#   terraform init
#   terraform apply -var github_repo=<owner>/crypto-market-platform
#
# The resulting terraform.tfstate is committed nowhere. If you lose it, import
# the four resources below rather than re-applying.
# ---------------------------------------------------------------------------
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  # Local state, deliberately. This is the only directory in the repo that has it.
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "required" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "bigquery.googleapis.com",
    "compute.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "billingbudgets.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# Versioned so a corrupted apply can be rolled back to the previous state file.
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-tfstate"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning { enabled = true }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Workload Identity Federation. GitHub Actions presents its OIDC token, GCP
# exchanges it for short-lived credentials for the deployer SA. No JSON key is
# ever created, so there is nothing to leak and nothing to rotate.
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  description               = "Keyless CI auth for ${var.github_repo}"

  depends_on = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Without this condition ANY GitHub repository in the world can mint tokens
  # for this pool. It is the single most important line in this file.
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# The deployer SA itself is created by envs/*, so bootstrap only wires the
# binding once it exists. Chicken-and-egg is resolved by running bootstrap
# twice: once for the bucket + pool, once after the first env apply.
data "google_service_account" "deployer" {
  count      = var.deployer_sa_email == "" ? 0 : 1
  project    = var.project_id
  account_id = var.deployer_sa_email
}

resource "google_service_account_iam_member" "wif_binding" {
  count = var.deployer_sa_email == "" ? 0 : 1

  service_account_id = data.google_service_account.deployer[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
