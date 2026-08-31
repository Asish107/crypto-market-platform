{{
  config(
    materialized         = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by         = {'field': 'event_date', 'data_type': 'date'},
    cluster_by           = ['product_id'],
    on_schema_change     = 'fail',
    contract             = {'enforced': true}
  )
}}

/*
  OHLCV bars at one-minute grain - the headline mart, and the shape almost
  every downstream consumer expects.

  ORDERING: open and close are taken by trade_id, not event_time. Multiple
  trades share a timestamp routinely (one taker order sweeping several resting
  orders all stamp the same millisecond), and ordering by time makes the open
  and close arbitrary among them. trade_id is the exchange's own authoritative
  sequence, so it breaks those ties the way the exchange itself would.

  VWAP is volume-weighted, not an average of prices. The distinction matters:
  a mean of trade prices weights a 0.00000007 BTC dust trade exactly as
  heavily as a 5 BTC block, and this market is full of dust.
*/

with trades as (

    select * from {{ ref('fct_trades') }}

    {% if is_incremental() %}
      where event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    {% endif %}

),

ordered as (

    select
        *,
        row_number() over (partition by product_id, event_minute order by trade_id asc)  as seq_asc,
        row_number() over (partition by product_id, event_minute order by trade_id desc) as seq_desc
    from trades

)

select
    product_id,
    event_minute                                                     as bar_start,
    timestamp_add(event_minute, interval 1 minute)                    as bar_end,

    -- OHLC
    max(if(seq_asc = 1, price, null))                                as open,
    max(price)                                                       as high,
    min(price)                                                       as low,
    max(if(seq_desc = 1, price, null))                               as close,

    -- Volume, in base units and quote currency
    sum(size)                                                        as volume,
    sum(notional)                                                    as quote_volume,
    count(*)                                                         as trade_count,

    -- Volume-weighted average price. safe_divide because an empty bar cannot
    -- occur here (no trades means no row) but a zero-size bar theoretically can.
    safe_divide(sum(notional), sum(size))                            as vwap,

    -- Taker-side split. taker_side is the AGGRESSOR - whoever crossed the
    -- spread. This is what "buy volume" means to anyone reading it.
    sum(if(taker_side = 'buy', size, 0))                             as buy_volume,
    sum(if(taker_side = 'sell', size, 0))                            as sell_volume,

    -- Order flow imbalance in [-1, 1]. Positive means buyers were the
    -- aggressors; it is the simplest usable measure of directional pressure.
    safe_divide(
        sum(if(taker_side = 'buy', size, 0)) - sum(if(taker_side = 'sell', size, 0)),
        sum(size)
    )                                                                as volume_imbalance,

    -- Data quality, carried on the bar itself so a consumer can filter on it
    -- without joining to another mart.
    cast(avg(ingest_lag_ms) as int64)                                as avg_ingest_lag_ms,
    min(trade_id)                                                    as first_trade_id,
    max(trade_id)                                                    as last_trade_id,

    date(event_minute)                                               as event_date

from ordered
group by product_id, event_minute
