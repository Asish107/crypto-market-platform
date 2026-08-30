# A budget you cannot see is a budget you will blow through. Notification
# channel first, then thresholds at 50/80/100 of forecast and actual.
resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Market platform alerts (${var.env})"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# Budgets live on the BILLING ACCOUNT, not the project, so no amount of
# project IAM lets CI manage them. This grant is the reason a `terraform apply`
# from GitHub Actions can touch the budget at all.
#
# Chicken-and-egg: CI cannot grant itself this. Apply it once from a laptop
# with roles/billing.admin, after which CI is self-sufficient.
resource "google_billing_account_iam_member" "deployer_cost_manager" {
  billing_account_id = var.billing_account
  role               = "roles/billing.costsManager"
  member             = "serviceAccount:${var.deployer_sa_email}"
}

# The Budgets API normalises a project ID into a project NUMBER on read. Writing
# the ID here means every plan shows a phantom diff forever, which trains people
# to ignore plan output - the exact opposite of what a plan is for.
data "google_project" "this" {
  project_id = var.project_id
}

resource "google_billing_budget" "this" {
  billing_account = var.billing_account
  display_name    = "crypto-market-platform-${var.env}"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Forecast catches a runaway Dataflow job days before actual spend does.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    disable_default_iam_recipients   = false
  }
}
