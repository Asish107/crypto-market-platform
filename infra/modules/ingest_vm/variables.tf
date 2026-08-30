variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }
variable "env" { type = string }

variable "enabled" {
  type        = bool
  default     = false
  description = "Gate the VM until an image has been pushed. A COS instance pointed at a nonexistent image boots into a crash loop that looks like a broken consumer."
}

variable "image" {
  type        = string
  description = "Full Artifact Registry image URL, tagged with a commit SHA. Never :latest - you cannot tell which code is running from a mutable tag."
  default     = ""
}

variable "machine_type" {
  type    = string
  default = "e2-small"
}

variable "products" {
  type = list(string)
}

variable "service_account_email" { type = string }

variable "labels" {
  type    = map(string)
  default = {}
}
