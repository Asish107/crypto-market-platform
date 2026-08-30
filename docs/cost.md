# Cost

Actuals go here once the platform has run a full month. Phase 1 estimate:

| Item | Phase 1 | Full platform |
|---|---|---|
| GCE e2-small (ingest) | — | ~$13/mo |
| Pub/Sub (5–8 GB) | ~$0 | ~$0 (10 GB free tier) |
| GCS storage + ops | ~$0 | ~$1/mo |
| BigQuery storage | ~$0 | ~$0.50/mo |
| BigQuery queries | ~$0 | ~$2/mo (1 TB/mo free) |
| Cloud Run (Dagster) | — | ~$8/mo |
| Cloud SQL f1-micro | — | ~$9/mo |
| **Total** | **~$0** | **~$34/mo** |
| Dataflow (burst only) | — | ~$3/hour while running |

Budget alert at $75 with thresholds at 50/80/100% of actual plus 100% of
forecast. The forecast threshold is the one that catches a Dataflow job left
running on a Friday.
