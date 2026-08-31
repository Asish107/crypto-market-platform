# ---------------------------------------------------------------------------
# The always-on ingest VM. Container-Optimized OS runs one container and
# restarts it on exit - no systemd unit to write, no OS to patch, and a
# read-only root filesystem by default.
#
# This is the only always-on compute in the platform (~$13/mo). Everything
# else is scheduled or scale-to-zero.
# ---------------------------------------------------------------------------

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "market-images"
  format        = "DOCKER"
  description   = "Consumer images, tagged by commit SHA."
  labels        = var.labels

  # Keep the last few builds for rollback; anything older is dead weight.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 10
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "puller" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.service_account_email}"
}

# GCP discontinued the `gce-container-declaration` metadata key - the old
# "container VM" startup agent - in 2025. The supported replacement on
# Container-Optimized OS is cloud-init, which is more explicit anyway: the
# systemd unit below is visible, greppable, and behaves like every other
# service on the box.
locals {
  cloud_init = <<-EOT
    #cloud-config

    write_files:
      - path: /etc/systemd/system/market-consumer.service
        permissions: "0644"
        owner: root
        content: |
          [Unit]
          Description=Coinbase market data consumer
          Wants=gcr-online.target
          After=gcr-online.target

          [Service]
          Environment=HOME=/home/consumer
          # Authenticate to Artifact Registry using the VM's own service
          # account. No key material on the box.
          ExecStartPre=/usr/bin/docker-credential-gcr configure-docker --registries=${var.region}-docker.pkg.dev
          ExecStartPre=-/usr/bin/docker rm -f market-consumer
          ExecStart=/usr/bin/docker run --rm --name market-consumer \
            --log-driver=gcplogs \
            -e GCP_PROJECT=${var.project_id} \
            -e PRODUCTS=${join(",", var.products)} \
            -e PUBLISH_ENABLED=true \
            -e METRICS_ENABLED=true \
            ${var.image}
          # SIGTERM triggers the consumer's graceful drain: stop reading, flush
          # queued publishes, exit. 30s is generous for a drain that is
          # normally instant.
          ExecStop=/usr/bin/docker stop --time=30 market-consumer
          Restart=always
          RestartSec=10

          [Install]
          WantedBy=multi-user.target

    runcmd:
      - systemctl daemon-reload
      - systemctl enable --now market-consumer.service
  EOT
}

resource "google_compute_instance" "ingest" {
  count = var.enabled ? 1 : 0

  project      = var.project_id
  name         = "market-ingest-${var.env}"
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable"
      size  = 10
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    # An ephemeral external IP purely for egress to the exchange. Cloud NAT
    # would be the tidier answer at ~$32/mo, which is more than the rest of
    # the platform combined for a single outbound connection.
    access_config {}
  }

  service_account {
    email = var.service_account_email
    # cloud-platform + IAM is the current pattern; legacy per-API scopes are a
    # second, weaker authorisation layer that hides real IAM errors behind
    # confusing scope errors.
    scopes = ["cloud-platform"]
  }

  metadata = {
    user-data                 = local.cloud_init
    config-hash               = substr(md5(local.cloud_init), 0, 12)
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }

  # The consumer is stateless: everything it knows is either in flight to
  # Pub/Sub or rebuildable from a fresh snapshot. Losing the VM costs a
  # reconnect, not data.
  allow_stopping_for_update = true

  # cloud-init runs ONCE, on first boot. Changing the image or the product
  # list rewrites the metadata but does nothing to the running box, so the VM
  # silently keeps its original config - it looks applied and isn't.
  #
  # Hashing the config into a metadata key that forces replacement makes the
  # instance immutable: any config change produces a NEW VM running the new
  # config. That is the correct model for a stateless consumer, and the outage
  # is one reconnect.
  metadata_startup_script = null

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    # Any change to the cloud-init config replaces the instance rather than
    # mutating metadata on a box that will never read it again.
    replace_triggered_by = [terraform_data.config_version]

    precondition {
      condition     = !var.enabled || var.image != ""
      error_message = "ingest_vm is enabled but no image was provided. Push an image and set var.image to its SHA-tagged URL."
    }
  }
}


# Carries the config hash so a change to cloud-init triggers instance
# replacement rather than a no-op metadata update.
resource "terraform_data" "config_version" {
  input = md5(local.cloud_init)
}
