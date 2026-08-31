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
        cast(json_value(change, '$[2]') as numeric)      as size,

        -- Position of this change WITHIN its message. One l2update carries
        -- many changes, all sharing the message's timestamp, and their array
        -- order is their sequence: the same price level can be removed and
        -- re-added inside a single message. Without this, ordering by time
        -- alone ties and the final state of that level is picked arbitrarily -
        -- which produced a book with the ask BELOW the bid.
        change_index

    from raw_events e,
         unnest(json_query_array(e.payload, '$.changes')) as change
         with offset as change_index
    where e.event_type = 'l2update'

),

-- Snapshots carry the whole book as bids[] and asks[] rather than a changes[]
-- array. They are the ONLY way to establish absolute state - deltas alone
-- describe changes to a book you do not have. Dropping them, as this model
-- originally did, makes reconstruction impossible.
-- BigQuery requires a CONSTANT path for JSON_QUERY_ARRAY, so bids and asks
-- cannot be selected through a lookup - they need one branch each.
snapshot_levels as (

    select
        e.product_id,
        e.event_type,
        timestamp(e.event_time)                          as event_time,
        timestamp(e.ingest_time)                         as ingest_time,
        e.publish_time,
        'buy'                                            as side,
        cast(json_value(level, '$[0]') as numeric)       as price,
        cast(json_value(level, '$[1]') as numeric)       as size,
        0                                                as change_index
    from raw_events e,
         unnest(json_query_array(e.payload, '$.bids')) as level
    where e.event_type = 'snapshot'

    union all

    select
        e.product_id,
        e.event_type,
        timestamp(e.event_time),
        timestamp(e.ingest_time),
        e.publish_time,
        'sell',
        cast(json_value(level, '$[0]') as numeric),
        cast(json_value(level, '$[1]') as numeric),
        0
    from raw_events e,
         unnest(json_query_array(e.payload, '$.asks')) as level
    where e.event_type = 'snapshot'

),

combined as (
    select * from flattened
    union all
    select * from snapshot_levels
)

select
    product_id,
    event_type,
    side,
    price,
    size,
    change_index,

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

from combined
