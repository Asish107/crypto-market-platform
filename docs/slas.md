# Service level objectives

Declared here, tested in dbt, alerted on in Cloud Monitoring. An SLA that is
not alerted on is a wish.

| Dataset | Freshness | Completeness | Enforced by |
|---|---|---|---|
| `raw.trades_stream` | < 60s | 99.99% | Monitoring alert on subscription age *(Phase 5)* |
| `marts.fct_bars_1m` | < 15 min | 99.9% | `assert_freshness` dbt test *(Phase 4)* |
| `marts.fct_realized_vol` | < 2 hours | 99.9% | `assert_freshness` dbt test *(Phase 4)* |

**Completeness** is measured as delivered trades over expected trades, where
expected is derived from sequence continuity in `stg_heartbeats` — not from a
row count, which cannot distinguish "quiet market" from "broken feed".

**Freshness** is measured from exchange `event_time`, not ingest time. Measuring
from ingest time would report a stalled feed as perfectly fresh.
