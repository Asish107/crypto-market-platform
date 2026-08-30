variable "project_id" { type = string }
variable "region" { type = string }
variable "env" { type = string }

variable "raw_retention_days" {
  type        = number
  description = "Hard retention lock on the raw lake. Objects cannot be deleted before this age, by anyone, including us."
}

variable "nearline_after_days" {
  type    = number
  default = 30
}
variable "coldline_after_days" {
  type    = number
  default = 90
}

variable "labels" {
  type    = map(string)
  default = {}
}
