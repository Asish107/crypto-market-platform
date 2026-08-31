# Streaming vs batch reconciliation

The deliverable of Phase 6 is not the streaming job. dbt already computes
1-minute bars, more cheaply, from the same source. The deliverable is a
**precise, queryable answer to "do the two paths agree, and when they don't,
why"** — because in a lambda architecture that question decides whether you
can trust either number.

## The run

| | |
|---|---|
| Job | `market-bars-recon-2` on Dataflow, `e2-standard-2`, 1 worker |
| Duration | ~15 minutes (burst, drained afterwards) |
| Source | `market.raw.trades.streaming`, a dedicated subscription |
| Windowing | Fixed 1 minute on **exchange event time** |
| Allowed lateness | 30 seconds |
| Accumulation | `ACCUMULATING` — each firing restates the whole window |
| Output | `curated.bars_1m_stream`, every pane including restatements |

## Result

Of the 78 product-minutes the streaming job produced:

| Outcome | Windows | Explanation |
|---|---|---|
| **agree** | **69** | Identical trade count, volume and close |
| `batch_not_yet_built` | 6 | Streaming is continuous; dbt is hourly. The newest window exists only in streaming until the next run. |
| `partial_window_at_startup` | 3 | The job started mid-minute and saw only part of that window. |
| **unexplained** | **0** | — |

**Agreement on comparable windows: 100%.** Every divergence has a mechanical
cause, and none of them is a defect in either path.

## What we expected to see, and didn't

The interesting prediction was **late-data loss**: a trade whose event time
falls in a window the watermark has already passed, arriving later than the
30-second grace period, is dropped by streaming and silently kept by batch.
That is the classic lambda divergence, and it never fired.

Why: Coinbase's feed is fast and our ingest lag is p99 ~166ms. A 30-second
grace period is roughly 180x the observed worst-case lateness, so nothing came
close to expiring. **The allowed-lateness setting is not currently doing any
work.** That is worth knowing precisely because it means the number is
untested, not because it is well chosen — the first sustained network problem
is when it would matter, and we would learn its value then rather than now.

## What DID fire: restatement

**69 of 72 windows were restated** — they emitted a second pane after their
first firing.

That is late data being caught *inside* the grace period and corrected, which
is exactly what accumulating panes are for. Had the trigger been
`DISCARDING`, each pane would have carried only the new trades, and any
consumer summing panes would have double counted. Had there been no late
trigger at all, those 69 windows would have been published wrong and never
corrected.

The distribution:

| Panes per window | Windows |
|---|---|
| 1 (fired once, never corrected) | 3 |
| 2 (fired, then restated with late data) | 69 |

## How the attribution was built, and why it took three attempts

The first version of `fct_stream_batch_recon` reported **0% agreement**. Each
subsequent version was more careful about attributing cause, and each revealed
the previous label was wrong:

1. **"late_data_dropped" (3 windows)** — actually the job's *first* window,
   partial because the job started mid-minute. Nothing to do with lateness.
2. **"over_count: BROKEN" (3 windows)** — actually batch schedule lag.
   Streaming is continuous, dbt is hourly; the newest windows legitimately
   exist only in streaming.
3. **"missing_from_batch: BROKEN" (1 window)** — same cause, but the
   classification checked "broken" before "expected", so the frontier case
   never got reached.

The lesson generalises beyond this model: **a reconciliation report that cries
wolf stops being read.** Ordering the `CASE` so expected conditions are
matched before failure conditions is not cosmetic — it is the difference
between a report someone acts on and one they learn to ignore.

## Cost

Dataflow is the only expensive component: ~$3/hour against a ~$34/month
baseline. It runs in bursts and is drained afterwards. This run cost
approximately **$0.75**.

Running it continuously would cost ~$2,160/year to recompute numbers dbt
already produces for a few dollars a month. The streaming path exists to
answer a question about correctness, not to serve data.
