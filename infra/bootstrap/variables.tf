variable "project_id" {
  type    = string
  default = "dataengproj01"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "github_repo" {
  type        = string
  description = "owner/repo, e.g. asish/crypto-market-platform. Scopes the WIF provider to exactly this repository."
}

variable "deployer_sa_email" {
  type        = string
  default     = ""
  description = "Leave empty on the first apply. After envs/dev has created the deployer SA, set it and re-apply to attach the WIF binding."
}
