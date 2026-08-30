# ---------------------------------------------------------------------------
# The raw lake. This bucket is the single source of truth for the whole
# platform: every mart must be rebuildable from it and nothing else. That
# property is only real if the bucket is genuinely immutable, hence versioning
# + a retention policy rather than a promise not to delete things.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "raw" {
  name                        = "${var.project_id}-market-raw"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false
  labels                      = var.labels

  versioning { enabled = true }

  # Retention is enforced by GCS, not by IAM. An operator with storage.admin
  # still cannot delete an object inside the window.
  retention_policy {
    retention_period = var.raw_retention_days * 86400
    is_locked        = false # flip to true in prod once you are sure; it is irreversible
  }

  lifecycle_rule {
    condition { age = var.nearline_after_days }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition { age = var.coldline_after_days }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  # Noncurrent versions exist only to survive an accidental overwrite; they are
  # not part of the replay path, so they do not need to live forever.
  lifecycle_rule {
    condition {
      num_newer_versions = 3
      with_state         = "ARCHIVED"
    }
    action { type = "Delete" }
  }
}

# Dead-letter payloads and drained subscriptions land here, separate from the
# lake so a DLQ drain can never be mistaken for clean raw data.
resource "google_storage_bucket" "quarantine" {
  name                        = "${var.project_id}-market-quarantine"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels

  lifecycle_rule {
    condition { age = 90 }
    action { type = "Delete" }
  }
}

# Build artifacts: dbt docs, elementary reports, recorded WS fixtures too large
# for git. Disposable by design.
resource "google_storage_bucket" "artifacts" {
  name                        = "${var.project_id}-market-artifacts"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.labels
}
