{{
  config(
    materialized      = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by      = {'field': 'event_date', 'data_type': 'date'},
    cluster_by        = ['product_id'],
    on_schema_change  = 'fail',
    contract          = {'enforced': true}
  )
}}

/*
  The deduped tick tape. The source of truth for everything downstream: bars,
  volume, VWAP, trade classification, realised volatility.

  INCREMENTAL STRATEGY - insert_overwrite on the date partition.

  Each run recomputes whole day-partitions within the lookback window and
  atomically replaces them. That is idempotent by construction: running it
  once, twice or ten times produces exactly the same table, which matters
  because backfills, retries and overlapping schedules all happen.

  The alternative, `merge` on trade_id, would be cheaper per run but leaves
  the table's contents dependent on the ORDER runs happened in. Replacing a
  whole partition has no such history.

  LOOKBACK - var('lookback_days'), 3 days. See dbt_project.yml for why.
*/

with trades as (

    select * from {{ ref('stg_trades') }}

    {% if is_incremental() %}
      -- Only reprocess the recent partitions. Without this, every hourly run
      -- rebuilds all of history.
      where event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    {% endif %}

)

select
    trade_id,
    product_id,
    sequence,
    price,
    size,
    notional,
    side,

    -- The taker is the aggressor: they crossed the spread to trade now rather
    -- than resting an order. `side` reports the MAKER's side, so a maker sell
    -- means the taker bought. Getting this backwards inverts every buy/sell
    -- volume imbalance downstream, and nothing about the number looks wrong.
    case side when 'sell' then 'buy' when 'buy' then 'sell' end
                                                         as taker_side,

    maker_order_id,
    taker_order_id,
    event_time,
    ingest_time,
    ingest_lag_ms,
    event_minute,
    event_date

from trades
