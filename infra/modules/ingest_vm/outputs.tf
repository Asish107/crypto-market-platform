output "repository_url" {
  value = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "instance_name" {
  value = var.enabled ? google_compute_instance.ingest[0].name : null
}

output "instance_zone" {
  value = var.zone
}
