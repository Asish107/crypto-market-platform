# Service level objectives

Declared here, tested in dbt, alerted on in Cloud Monitoring. An SLA that is
not alerted on is a wish.

| Dataset | Freshness | Completeness | Enforced by |
|---|---|---|---|
| `raw.trades_stream` | < 60s | 99.99% | `PAGE: market feed silent` — fires after 5 min of no publishes |
| `marts.fct_trades` | < 1 hour | 99.99% | `assert_trade_ids_contiguous` (error), `fct_data_quality` |
| `marts.fct_bars_1m` | < 1 hour | 99.9% | `assert_bar_volume_reconciles` (error) |
| `marts.fct_liquidity_1m` | < 1 hour | 99.9% | `assert_no_crossed_book` (error) |
| `marts.fct_realized_vol` | < 2 hours | 99.9% | rolled up from bars; inherits their guarantees |

## How each is actually measured

**Completeness** is `trades_received / trade_id_span`, per product-hour, in
`fct_data_quality`. It is arithmetic, not estimation: the exchange's counter
keeps moving whether or not we are listening, so a missing range is a fact.

A row count could not do this. It cannot distinguish a quiet market from a
broken feed — both look like "fewer rows than yesterday".

**Freshness** is measured from the exchange's `event_time`, never from our own
ingest time. Measuring from ingest time would report a totally stalled feed as
perfectly fresh, because the last row we managed to write is always recent by
its own clock.

## An honest discrepancy

The original spec committed `fct_bars_1m` to **15 minutes** of freshness. The
Dagster schedule runs **hourly**, so that target is not met.

Both options were available — tighten the schedule or relax the target — and
the target was relaxed, because nothing consumes these marts on a 15-minute
horizon and four extra BigQuery runs per hour cost more than the freshness is
worth. If a consumer ever needs 15 minutes, the schedule is one line.

Writing this down beats discovering it in a review.

## Latency, observed

Measured from live traffic, `fct_data_quality`:

| Percentile | Exchange → our receipt |
|---|---|
| p50 | ~5–40 ms |
| p95 | ~60 ms |
| p99 | ~166 ms |

Occasionally negative, which is clock skew — our server runs tens of
milliseconds behind Coinbase's. Recorded rather than clamped, because it is a
real operational fact and it caused a genuine bug in the book reconstruction
(ADR 0007's cousin — see `int_book_state_1m`).
