variable "project_id" { type = string }
variable "billing_account" { type = string }
variable "env" { type = string }

variable "monthly_budget_usd" {
  type        = number
  description = "Hard ceiling for the whole platform. The spec budgets ~$34/mo baseline; this is the alarm, not the plan."
}

variable "alert_email" { type = string }
