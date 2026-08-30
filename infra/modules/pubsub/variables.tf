variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "schema_dir" { type = string }
variable "raw_bucket" { type = string }
variable "bq_raw_dataset" { type = string }

variable "publisher_sa_email" {
  type        = string
  description = "The ingest VM's service account. The only identity allowed to publish."
}

variable "gcs_flush_bytes" {
  type        = number
  default     = 64 * 1024 * 1024
  description = "Native GCS sink flushes on whichever of bytes/duration hits first."
}

variable "gcs_flush_duration" {
  type    = string
  default = "300s"
}

variable "labels" {
  type    = map(string)
  default = {}
}
