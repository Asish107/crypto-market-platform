# Every command an operator needs, in one place. If a step is not here, it is
# not reproducible.

PROJECT_ID ?= dataengproj01
REGION     ?= us-central1
ENV        ?= dev
TF_DIR     := infra/envs/$(ENV)
STATE_BUCKET := $(PROJECT_ID)-tfstate

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- one-time -------------------------------------------------------------

.PHONY: bootstrap
bootstrap: ## Create the tfstate bucket + WIF pool (local state, run once)
	cd infra/bootstrap && terraform init && terraform apply

# --- infrastructure -------------------------------------------------------

.PHONY: init
init: ## terraform init for $(ENV)
	cd $(TF_DIR) && terraform init -backend-config="bucket=$(STATE_BUCKET)"

.PHONY: plan
plan: init ## terraform plan for $(ENV)
	cd $(TF_DIR) && terraform plan -input=false

.PHONY: up
up: init ## terraform apply for $(ENV)
	cd $(TF_DIR) && terraform apply -input=false

.PHONY: down
down: init ## terraform destroy for $(ENV) -- must always work end to end
	cd $(TF_DIR) && terraform destroy -input=false

.PHONY: outputs
outputs:
	cd $(TF_DIR) && terraform output

.PHONY: fmt
fmt: ## Format all terraform
	terraform fmt -recursive infra

.PHONY: validate
validate: init
	cd $(TF_DIR) && terraform validate

# --- code -----------------------------------------------------------------

.PHONY: lint
lint: ## ruff + mypy, exactly as CI runs them
	ruff check ingest streaming orchestration
	ruff format --check ingest streaming orchestration
	mypy ingest/src

.PHONY: test
test: ## pytest
	pytest ingest/tests -q

.PHONY: check
check: fmt lint test validate ## Everything CI runs, locally

# --- operations (phases 2+) ----------------------------------------------

.PHONY: smoke
smoke: ## Publish one synthetic message and prove it lands in GCS and BigQuery
	@scripts/smoke_test.sh $(PROJECT_ID)

.PHONY: backfill
backfill: ## Rebuild marts from the lake. FROM=YYYY-MM-DD TO=YYYY-MM-DD
	@echo "Phase 3: dagster job execute -j backfill_from_lake --config from=$(FROM) to=$(TO)"
