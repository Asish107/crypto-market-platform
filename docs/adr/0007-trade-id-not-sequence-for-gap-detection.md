# ADR 0007: Detect gaps on `trade_id`, not `sequence`

**Status:** accepted · **Date:** 2026-08-30

## Context

The whole project rests on being able to prove data was not lost. Coinbase
documents that the feed can drop and reorder messages, and every message
carries a `sequence` field, so the obvious design tracks `sequence` continuity
per product and reports a gap on any discontinuity.

That design was built, tested against fixtures, and passed. Pointed at the live
feed it reported **hundreds of missing messages per second** on a completely
healthy connection.

## What is actually true

Verified directly against `wss://ws-feed.exchange.coinbase.com`:

| Message type | Carries `sequence`? |
|---|---|
| `match` / `last_match` | yes |
| `heartbeat` | yes |
| **`l2update`** | **no** |

And crucially: **`sequence` counts every order-book event for the product** -
order received, open, done, change - the overwhelming majority of which arrive
only on the `full` channel, which we deliberately do not subscribe to (§2:
three channels, `matches`, `level2_batch`, `heartbeat`).

So consecutive `match` messages legitimately differ in `sequence` by hundreds.
Measured on our channels, `sequence` continuity is meaningless.

Observed live:

```
sequence: 135275402983 -> 135275402985 -> 135275403033 -> 135275403141
trade_id: 1086234192   -> 1086234193   -> 1086234194   -> 1086234195
```

## Decision

Detect gaps on **`trade_id`**, which is strictly contiguous per product (+1 per
trade, verified). Keep `sequence` in the raw payload - it is part of the record
and is meaningful to anyone who later consumes the `full` channel - but do not
derive continuity from it.

Add a second, independent detector: **compare `heartbeat.last_trade_id` against
the highest `trade_id` we have seen.**

## Why the heartbeat check earns its place

It catches a gap the trade stream *cannot*. If trades 508-510 never arrive as
messages at all, the match stream has no discontinuity to notice - you cannot
observe the absence of a message you never received. The heartbeat is an
independent statement from the exchange about what it believes the latest trade
is, so it is the only witness to that class of loss.

The heartbeat legitimately *lags* the match stream, so only a heartbeat **ahead**
of us is evidence of loss.

## Verification

Both detectors are exercised by `ingest/tests/test_replay.py` against a
recorded session with injected faults, and confirmed in SQL against live data:

```sql
SELECT product_id, COUNT(*) = MAX(trade_id) - MIN(trade_id) + 1 AS contiguous
FROM raw.trades_stream GROUP BY product_id
-- BTC-USD true · ETH-USD true · SOL-USD true
```

## What we give up

- **No continuity signal for `level2_batch`.** `l2update` carries no counter of
  any kind, so a dropped book delta is undetectable at the message level. The
  compensating control is the crossed-book invariant: a book that has drifted
  will eventually produce `bid >= ask`, which is checked on every update and
  alerted on. It is a weaker guarantee, and it is the honest state of affairs
  rather than a gap in the design nobody wrote down.
- **`sequence` remains in the schema** doing nothing for us today. Removing it
  would be a breaking schema change to save eight bytes, and it is genuinely
  useful if the `full` channel is ever added.

## The general lesson

Fixture tests confirmed the consumer did what I designed. They could not tell
me the design was measuring the wrong number, because I wrote the fixtures from
the same wrong assumption as the code. **Only the live feed could falsify it.**
