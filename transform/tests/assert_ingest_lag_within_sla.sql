/*
  Freshness, measured from the EXCHANGE's timestamp rather than ours.

  Measuring from ingest_time would report a completely stalled feed as
  perfectly fresh, because the last row we managed to write is always recent
  by its own clock.

  Negative lag is clock skew, not an error, so this tests the absolute value
  and only at p99 - a single slow message is normal, a sustained tail is not.
*/

with lag_percentiles as (

    select
        product_id,
        approx_quantiles(abs(ingest_lag_ms), 100)[offset(99)] as p99_lag_ms
    from {{ ref('fct_trades') }}
    where event_date >= date_sub(current_date(), interval 1 day)
      -- Backfilled rows are excluded deliberately. Their lag is the duration
      -- of the outage they recovered from, so including them means any
      -- successful recovery fails the latency SLA - punishing the fix rather
      -- than the fault. Found by the recovery drill (docs/recovery-drill.md).
      and not is_backfilled
    group by 1

)

select *
from lag_percentiles
where p99_lag_ms > 5000   -- 5s, per docs/slas.md
