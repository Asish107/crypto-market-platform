{{ config(materialized = 'view') }}

/*
  Heartbeats are the independent witness. Each one states the exchange's view
  of the latest trade id for a product, which is the only way to detect trades
  that never arrived as messages at all - you cannot notice the absence of a
  message you never received.
*/

with raw_heartbeats as (

    select
        product_id,
        sequence,
        last_trade_id,
        event_time,
        ingest_time,
        publish_time
    from {{ source('raw', 'heartbeat_stream') }}
    where {{ raw_partition_filter() }}

),

-- BigQuery cannot reference a column alias elsewhere in the same SELECT list,
-- so the casts have to land in their own CTE before anything derives from them.
-- Without this, date(event_time) silently reads the raw STRING column.
typed as (

    select
        product_id,
        cast(sequence as int64)                          as sequence,
        cast(last_trade_id as int64)                     as last_trade_id,
        timestamp(event_time)                            as event_time,
        timestamp(ingest_time)                           as ingest_time,
        publish_time
    from raw_heartbeats

)

select
    product_id,
    sequence,
    last_trade_id,
    event_time,
    ingest_time,
    publish_time,
    timestamp_diff(ingest_time, event_time, MILLISECOND) as ingest_lag_ms,
    date(event_time)                                     as event_date,
    timestamp_trunc(event_time, MINUTE)                  as event_minute

from typed
