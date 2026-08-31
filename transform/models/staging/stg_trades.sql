{{
  config(
    materialized = 'view'
  )
}}

/*
  The tick tape, cleaned. Three jobs and nothing else:

    1. cast     - raw keeps everything as strings on purpose; this is where
                  price and size become numbers and times become timestamps
    2. dedupe   - the exchange replays trades on reconnect, so the same
                  trade_id genuinely arrives more than once
    3. measure  - ingest_lag_ms, computed here so every downstream model
                  agrees on what "lag" means

  No business logic. If this model is ever interesting, something belongs in
  intermediate/ instead.
*/

with raw_trades as (

    select
        trade_id,
        product_id,
        sequence,
        price,
        size,
        side,
        maker_order_id,
        taker_order_id,
        event_time,
        ingest_time,
        publish_time,
        message_id

    from {{ source('raw', 'trades_stream') }}
    where {{ raw_partition_filter() }}
      -- Only real market data reaches the marts. Two guards,
      -- because a single bad row corrupts trade-id contiguity for a whole
      -- product-day and contiguity is how we prove nothing was lost.
      and product_id in ({{ "'" ~ var('tracked_products') | join("','") ~ "'" }})
      and cast(trade_id as int64) not in ({{ var('synthetic_trade_ids') | join(', ') }})

),

-- BigQuery cannot reference a column alias elsewhere in the same SELECT list,
-- so casts land in their own CTE before anything derives from them. Without
-- this separation, `price * size` silently multiplies two STRINGs and fails,
-- and `date(event_time)` would read the raw string rather than the timestamp.
typed as (

    select
        cast(trade_id as int64)                          as trade_id,
        product_id,
        cast(sequence as int64)                          as sequence,

        -- NUMERIC, not FLOAT64. Binary floating point cannot represent 0.1,
        -- and a VWAP over millions of trades accumulates that error into
        -- something a trader would notice.
        cast(price as numeric)                           as price,
        cast(size as numeric)                            as size,

        side,
        nullif(maker_order_id, '')                       as maker_order_id,
        nullif(taker_order_id, '')                       as taker_order_id,

        timestamp(event_time)                            as event_time,
        timestamp(ingest_time)                           as ingest_time,
        publish_time,
        message_id

    from raw_trades

),

derived as (

    select
        *,

        price * size                                     as notional,

        -- Backfilled rows carry sequence = 0: the REST endpoint does not
        -- expose the feed's sequence, and scripts/backfill_trades.py writes
        -- zero rather than inventing a plausible value.
        --
        -- This matters more than it looks. A backfilled trade has an
        -- event_time from whenever it happened and an ingest_time of whenever
        -- we recovered it, so its "lag" is the length of the outage - correct
        -- arithmetic measuring something entirely different from live latency.
        -- Mixing the two makes the latency SLA meaningless after any recovery.
        sequence = 0                                     as is_backfilled,

        -- Exchange timestamp to our receive time. Can be NEGATIVE when our
        -- clock runs behind the exchange's; that is clock skew, and hiding it
        -- by clamping to zero would hide a genuine operational problem.
        timestamp_diff(ingest_time, event_time, MILLISECOND) as ingest_lag_ms

    from typed

),

deduped as (

    select
        *,
        row_number() over (
            partition by trade_id, product_id
            -- Keep the EARLIEST arrival. A replayed copy is by definition the
            -- later one, and its ingest_time would overstate our latency.
            order by ingest_time asc, publish_time asc
        ) as _row_num
    from derived

)

select
    trade_id,
    product_id,
    sequence,
    price,
    size,
    side,
    notional,
    is_backfilled,
    maker_order_id,
    taker_order_id,
    event_time,
    ingest_time,
    publish_time,
    ingest_lag_ms,
    date(event_time)                                     as event_date,
    timestamp_trunc(event_time, MINUTE)                  as event_minute

from deduped
where _row_num = 1
