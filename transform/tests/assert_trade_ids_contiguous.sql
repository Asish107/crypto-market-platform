/*
  The core data-loss test.

  trade_id is contiguous per product (+1 per trade), so within any window the
  number of distinct trades MUST equal the id span. A shortfall is trades that
  never reached us.

  This is the SQL form of the same invariant the consumer checks in memory -
  deliberately duplicated, because the consumer only sees what it received and
  cannot audit what was written. A gap introduced by a publish failure, a
  dropped Pub/Sub message or a bad dedupe would be invisible in-process and
  visible here.

  Fails when loss exceeds the 0.01%/hour SLA in docs/slas.md.

  Note the exclusion of the CURRENT day: a partial day is legitimately
  incomplete, and comparing it against a full id span always reports a gap.
*/

with by_product_day as (

    select
        product_id,
        event_date,
        count(distinct trade_id)                     as trades_seen,
        max(trade_id) - min(trade_id) + 1            as id_span
    from {{ ref('fct_trades') }}
    where event_date < current_date()
      and event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    group by 1, 2

)

select
    product_id,
    event_date,
    trades_seen,
    id_span,
    id_span - trades_seen                            as missing,
    safe_divide(id_span - trades_seen, id_span) * 100 as missing_pct
from by_product_day
where safe_divide(id_span - trades_seen, id_span) > 0.0001   -- 0.01%
