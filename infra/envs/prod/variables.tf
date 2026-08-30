variable "project_id" {
  type    = string
  default = "dataengproj01"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "billing_account" {
  type        = string
  description = "Billing account id, format XXXXXX-XXXXXX-XXXXXX. Find it with: gcloud billing projects describe dataengproj01"
}

variable "alert_email" {
  type = string
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "products" {
  type        = list(string)
  description = "Products to subscribe to. Three is enough to prove multi-tenancy without tripling cost."
  default     = ["BTC-USD", "ETH-USD", "SOL-USD"]
}

variable "ingest_vm_enabled" {
  type    = bool
  default = false
}

variable "ingest_image" {
  type    = string
  default = ""
}
