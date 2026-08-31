# Recovery drill

The most convincing artefact in this repository, because it is the only one
that proves the platform survives something going wrong rather than asserting
it will.

**Executed 2026-08-31, against the live platform.** Not simulated.

## Method

1. Snapshot the marts.
2. **Kill the consumer VM mid-stream.** Leave it dead.
3. Confirm the feed is genuinely silent, not just quiet.
4. Restart. Measure the gap exactly.
5. Backfill from the Coinbase REST API.
6. Prove the gap is closed and the marts are whole.

## Timeline

| Time (UTC) | Event |
|---|---|
| 01:45:17 | Pre-outage snapshot: BTC at trade 1086348883 |
| **01:48:35** | **`gcloud compute instances stop` — VM killed mid-stream** |
| 01:49:55 | 1,832 trades still landing (in-flight and buffered) |
| 01:54:05 | **Feed confirmed silent** — zero trades in 5 minutes |
| **01:54:19** | VM restarted |
| 01:55:16 | **Feed resumed** — 57 seconds from cold start to live data |
| 01:56:00 | Gap measured exactly from `trade_id` contiguity |
| 01:57:00 | Backfill executed from the REST API |
| 02:00:10 | **100% completeness restored** |

Total outage: **6 minutes 41 seconds.** Total recovery: **under 5 minutes.**

## The gap, measured not estimated

Because `trade_id` is contiguous per product, the missing range is arithmetic:

| Product | Last held | Resumed at | Trades lost | Duration |
|---|---|---|---|---|
| BTC-USD | 1086349833 | 1086351563 | **1,729** | 378s |
| ETH-USD | 839634249 | 839635131 | **881** | 382s |
| SOL-USD | 351156290 | 351156886 | **595** | 382s |

**3,205 trades lost.** Not "roughly three thousand" — exactly 3,205, with the
precise ids known, which is what makes the backfill a lookup rather than a
reconstruction.

## Why the lake could not help

The GCS lake is the system of record for everything the platform *received*.
During an outage nothing was received, so replaying the lake reproduces the gap
perfectly.

This is worth stating plainly because it is a limit of the immutable-lake
pattern that is easy to gloss over: **the lake protects against everything
downstream of ingestion, and nothing upstream of it.** A transformation bug, a
bad deploy, a dropped table — all recoverable from the lake. A dead consumer is
not.

Recovery from an ingestion outage has to go back to the source, which is why
`scripts/backfill_trades.py` exists.

## The backfill

Backfilled trades are published to the **same Pub/Sub topic** as live ones. They
pass the same schema validation, land in both sinks, and dedupe in staging on
`trade_id`. There is no second code path that could behave differently, and
re-running is safe.

```
published 1729 backfilled trades to market.raw.trades   # BTC-USD
published  881 backfilled trades to market.raw.trades   # ETH-USD
published  595 backfilled trades to market.raw.trades   # SOL-USD
```

## Result

| Product | Trades in hour | Missing | Completeness | Backfilled | p99 lag | SLAs |
|---|---|---|---|---|---|---|
| BTC-USD | 17,795 | **0** | **100.00%** | 2,889 | 251ms | ✅ ✅ |
| ETH-USD | 8,832 | **0** | **100.00%** | 1,365 | 302ms | ✅ ✅ |
| SOL-USD | 7,934 | **0** | **100.00%** | 1,066 | 335ms | ✅ ✅ |

`assert_trade_ids_contiguous` passes. The tape is whole.

## What the drill found

A drill that goes exactly to plan has told you nothing. This one found a real
flaw in the platform's own instrumentation.

**`assert_ingest_lag_within_sla` failed immediately after a successful
recovery.**

Backfilled trades carry an `event_time` from when the trade happened and an
`ingest_time` from when it was recovered — so their measured "lag" was the
length of the outage, ~400 seconds against a 5-second SLA. Correct arithmetic,
measuring entirely the wrong thing.

The consequence is worse than a noisy test: **the latency SLA would fail for as
long as backfilled rows sat in the window, punishing the fix rather than the
fault.** An operator who recovers from an outage and is rewarded with a second
failing alert learns to stop recovering carefully.

The fix distinguishes the two populations. Backfilled rows are marked
(`is_backfilled`, from the `sequence = 0` the backfill script writes), excluded
from every latency measure, and counted separately in `fct_data_quality` — so
an hour containing recovered trades is visibly not the same as an hour that
never broke, even though both read 100% complete.

**None of this was visible until the platform actually had to recover.**

## Rerunning the drill

Quarterly, not once. The point is that it keeps working.

```bash
gcloud compute instances stop market-ingest-dev --zone us-central1-a --project dataengproj01
# wait for the "feed silent" alert to fire
gcloud compute instances start market-ingest-dev --zone us-central1-a --project dataengproj01
# then follow docs/runbook.md, "Backfill a gap from the exchange"
```
