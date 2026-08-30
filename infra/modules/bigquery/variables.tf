variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }
variable "raw_bucket" { type = string }

variable "raw_table_expiration_days" {
  type        = number
  description = "Raw BigQuery tables are a convenience cache over the lake, not the system of record, so they are allowed to age out."
}

variable "dbt_sa_email" { type = string }

variable "labels" {
  type    = map(string)
  default = {}
}
