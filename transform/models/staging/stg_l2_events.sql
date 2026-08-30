{{ config(materialized = 'view') }}

/*
  Order book events, with the JSON delta array flattened into one row per
  price-level change.

  The raw layer carries `changes` as an opaque JSON string on purpose: the
  shape is Coinbase's to change, and the lake should not need a migration when
  they add a field. Unpacking it is this model's job.

  Note there is no continuity counter available here at all - `l2update`
  carries no sequence and no id (ADR 0007). A dropped book delta is
  undetectable at the message level; the compensating control is the
  crossed-book invariant checked in the consumer and asserted downstream.
*/

with raw_events as (

    select
        product_id,
        event_type,
        payload,
        event_time,
        ingest_time,
        publish_time
    from {{ source('raw', 'l2_stream') }}
    where {{ raw_partition_filter() }}

),

flattened as (

    select
        e.product_id,
        e.event_type,
        timestamp(e.event_time)                          as event_time,
        timestamp(e.ingest_time)                         as ingest_time,
        e.publish_time,

        -- Each change is [side, price, size].
        json_value(change, '$[0]')                       as side,
        cast(json_value(change, '$[1]') as numeric)      as price,
        cast(json_value(change, '$[2]') as numeric)      as size

    from raw_events e,
         unnest(json_query_array(e.payload, '$.changes')) as change
    where e.event_type = 'l2update'

)

select
    product_id,
    event_type,
    side,
    price,
    size,

    -- A size of zero is a REMOVAL, not a resting order of zero size. Any model
    -- reconstructing book state must treat it as a delete; treating it as a
    -- level leaves phantom liquidity in the book forever.
    size = 0                                             as is_removal,

    event_time,
    ingest_time,
    publish_time,
    timestamp_diff(ingest_time, event_time, MILLISECOND) as ingest_lag_ms,
    date(event_time)                                     as event_date,
    timestamp_trunc(event_time, MINUTE)                  as event_minute

from flattened
