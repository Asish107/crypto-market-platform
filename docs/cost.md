# Cost

## Actual, as configured today

| Item | Monthly | Notes |
|---|---|---|
| GCE `e2-small` (ingest, always on) | ~$13 | The only continuously running compute |
| External IP (ephemeral) | ~$3 | Egress to the exchange; Cloud NAT would be ~$32 |
| Pub/Sub | ~$0 | ~5–8 GB against a 10 GB free tier |
| GCS (lake + artifacts) | ~$1 | Standard → Nearline 30d → Coldline 90d |
| BigQuery storage | ~$0.50 | Raw expires at 14 days; marts are tiny |
| BigQuery queries | ~$0 | Well inside the 1 TB/month free tier |
| Cloud Monitoring / Logging | ~$0 | Inside free allotments at this volume |
| **Running total** | **~$17.50/mo** | |

## Not yet deployed

| Item | Monthly | Status |
|---|---|---|
| Cloud Run (Dagster webserver + daemon) | ~$8 | Definitions written and verified on Linux; not deployed |
| Cloud SQL `db-f1-micro` (Dagster run storage) | ~$9 | Same |
| **Full platform** | **~$34/mo** | Matches the original estimate |

## Burst only

| Item | Rate | Actual spend |
|---|---|---|
| Dataflow (`e2-standard-2`, 1 worker) | ~$3/hour | ~$0.75 for the 15-minute reconciliation run |

Running Dataflow continuously would cost **~$2,160/year** to recompute numbers
dbt already produces for a few dollars a month. It exists to answer a question
about correctness (see [reconciliation.md](reconciliation.md)), not to serve
data. Drain it when the question is answered.

## Guardrails

- Budget of **$25/month** on dev, alerting at 50 / 80 / 100% of actual **and**
  100% of forecast. The forecast threshold is the one that catches a Dataflow
  job left running on a Friday — actual spend would not cross a threshold until
  Sunday.
- `require_partition_filter = true` on every raw table, so an accidental
  full-table scan **fails** rather than quietly billing for one.
- Raw BigQuery tables expire at 14 days. The lake is the system of record; the
  warehouse copy is a cache and is priced like one.

## The decision that dominates the bill

Choosing Pub/Sub's native sinks over a Dataflow ingest job (ADR 0002) is worth
about **$70/month** — roughly four times the entire current running cost. It is
the single largest cost decision in the platform, and it also removed a job
graph, a worker pool and drain semantics from the on-call surface.
