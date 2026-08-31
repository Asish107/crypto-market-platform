variable "project_id" { type = string }
variable "env" { type = string }

variable "notification_channel_id" {
  type        = string
  description = "Reused from the budget module rather than created again, so every alert lands in one place."
}

variable "products" { type = list(string) }
