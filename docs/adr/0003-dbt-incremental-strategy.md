# ADR 0003: `insert_overwrite` on the date partition, 3-day lookback

**Status:** accepted · **Date:** 2026-08-31

## Context

Marts must refresh hourly without rebuilding all of history, while tolerating
late-arriving data — the exchange replays trades on reconnect, and a backfill
can write into any past day.

## Decision

`incremental_strategy = 'insert_overwrite'`, partitioned by `event_date`, with
a 3-day lookback window.

Each run recomputes whole day-partitions inside the window and atomically
replaces them.

## Rationale

**Idempotency by construction.** Running the model once, twice, or ten times
produces exactly the same table. That matters because retries, overlapping
schedules and manual backfills all happen, and a model whose output depends on
how many times it ran is not a fact table.

The obvious alternative, `merge` on `trade_id`, is cheaper per run but leaves
the table's contents dependent on the ORDER runs happened in. Replacing a whole
partition has no history to get wrong.

**Why 3 days.** The window is a real SLA, not a default:

- Pub/Sub retains 7 days, so anything older cannot arrive through the normal path
- The exchange replays only recent trades on reconnect — seconds, not days
- A 3-day window costs three partition rewrites per run, which is trivial at
  this volume

Data arriving later than 3 days is a recovery scenario, and recovery should be
an explicit backfill someone chose to run, not something the hourly job does
silently. A lookback wide enough to absorb every case is a lookback that hides
the fact that something went wrong.

## What we give up

- **Late data past 3 days is invisible** until someone runs a backfill. The
  `fct_data_quality` mart is what surfaces the need.
- **Partition rewrite is all-or-nothing.** A partition is briefly replaced
  rather than updated in place. BigQuery makes this atomic, so readers never
  see a half-written partition, but the cost is proportional to partition size
  rather than to how much changed.
