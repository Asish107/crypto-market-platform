# Data dictionary

Generated reference: `dbt docs generate --project-dir transform --profiles-dir transform`,
then `dbt docs serve`. Column-level descriptions live in the `_*.yml` files
beside each model and are the source of truth.

This page is the orientation layer — what each table is *for*, which is the part
generated docs never capture.

## marts

| Table | Grain | Use it when you want | Do not use it for |
|---|---|---|---|
| `fct_trades` | trade | The tick tape. The source of truth everything else derives from. | Anything aggregate — the bars exist for that |
| `fct_bars_1m` | product × minute | OHLCV, VWAP, order-flow imbalance | Knowing whether you could have *traded* at that price |
| `fct_bars_5m` / `fct_bars_1h` | product × window | Coarser views, rolled up from 1m | Recomputing from ticks — they are rollups by design |
| `fct_liquidity_1m` | product × minute | Spread, depth, book imbalance: the cost of trading | Deep book structure — the book is pruned to ±1% of mid |
| `fct_realized_vol` | product × hour | Volatility by three estimators | Sub-hourly volatility |
| `fct_data_quality` | product × hour | **Whether to trust any of the above** | — |
| `fct_stream_batch_recon` | product × minute | Where streaming and batch disagree, and why | Serving data — it is an audit artefact |
| `dim_products` | product | Tick size, minimum size, naming | — |

## The columns worth understanding before you query anything

**`side` vs `taker_side`.** `side` is the **maker's** side, as the exchange
reports it. `taker_side` is the aggressor — whoever crossed the spread. When
anyone says "buy volume" they mean `taker_side = 'buy'`. Using `side` inverts
every imbalance figure, and the resulting numbers look entirely plausible.

**`ingest_lag_ms` can be negative.** That is clock skew: our server runs tens of
milliseconds behind Coinbase's. Not clamped, because it is a real operational
fact — and it caused a genuine bug in the book reconstruction (see
`int_book_state_1m`).

**`is_backfilled`.** Recovered from the REST API rather than received live.
Their lag measures the duration of an outage, not pipeline latency, so every
latency measure excludes them. See [recovery-drill.md](recovery-drill.md).

**`sequence` is not a continuity counter.** It counts every order-book event on
the pair, most of which arrive on a channel we do not subscribe to. Use
`trade_id`. See [ADR 0007](adr/0007-trade-id-not-sequence-for-gap-detection.md).

**`completeness_pct` is arithmetic, not estimation.** Trades received over the
`trade_id` span. A row count cannot distinguish a quiet market from a broken
feed; this can.

## Querying raw

Every raw table has `require_partition_filter = true`, so a query without a
partition predicate **fails** rather than quietly scanning everything. Include
the streaming buffer or you will miss the newest rows:

```sql
WHERE (_PARTITIONTIME IS NULL
       OR _PARTITIONTIME >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY))
```

Rows arriving through the streaming path sit in an unpartitioned buffer with a
NULL `_PARTITIONTIME` until BigQuery commits them to a date partition. Filtering
on the date alone excludes precisely the rows you just wrote.
