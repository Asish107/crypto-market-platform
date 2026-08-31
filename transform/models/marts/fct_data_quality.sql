{{
  config(
    materialized         = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by         = {'field': 'event_date', 'data_type': 'date'},
    cluster_by           = ['product_id'],
    on_schema_change     = 'fail'
  )
}}

/*
  The pipeline measuring itself, in SQL, as a first-class mart.

  Every other mart answers a question about the market. This one answers
  "should you believe them?" - and it is queryable, historical, and tested the
  same way as anything else, rather than living in a monitoring tool where it
  cannot be joined to the data it describes.

  Grain: product x hour.

  The measures that matter:

    completeness_pct - trades received over trades that EXIST. Derived from
                       trade_id contiguity, not from a row count. A row count
                       cannot distinguish a quiet market from a broken feed;
                       contiguity can, because the exchange's counter keeps
                       moving whether or not we are listening.

    trades_missing   - the count, so a percentage near 100 can still be
                       interrogated.

    p50/p99 lag      - measured from EXCHANGE event time. Measuring from our
                       own ingest time would report a totally stalled feed as
                       perfectly fresh.

    duplicates       - replayed trades removed by staging. A spike means the
                       consumer is reconnecting, which is a health signal even
                       though the data is correct.
*/

with trades as (

    select
        product_id,
        trade_id,
        event_time,
        ingest_lag_ms,
        is_backfilled,
        timestamp_trunc(event_time, HOUR) as event_hour,
        event_date
    from {{ ref('fct_trades') }}

    {% if is_incremental() %}
      where event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    {% endif %}

),

-- Deduped rows survive into fct_trades; the raw layer still holds every copy.
-- The difference is how many the exchange replayed at us.
raw_counts as (

    select
        product_id,
        timestamp_trunc(timestamp(event_time), HOUR) as event_hour,
        count(*)                                     as raw_rows,
        count(distinct trade_id)                     as distinct_trades
    from {{ source('raw', 'trades_stream') }}
    where {{ raw_partition_filter() }}
      and product_id in ({{ "'" ~ var('tracked_products') | join("','") ~ "'" }})
      and cast(trade_id as int64) not in ({{ var('synthetic_trade_ids') | join(', ') }})
    group by 1, 2

),

per_hour as (

    select
        product_id,
        event_hour,
        any_value(event_date)                                   as event_date,

        count(*)                                                as trades_received,
        min(trade_id)                                           as first_trade_id,
        max(trade_id)                                           as last_trade_id,
        max(trade_id) - min(trade_id) + 1                       as trade_id_span,

        -- Live rows only: a backfilled row's lag is the outage duration.
        approx_quantiles(if(not is_backfilled, abs(ingest_lag_ms), null), 100)[offset(50)] as p50_ingest_lag_ms,
        approx_quantiles(if(not is_backfilled, abs(ingest_lag_ms), null), 100)[offset(95)] as p95_ingest_lag_ms,
        approx_quantiles(if(not is_backfilled, abs(ingest_lag_ms), null), 100)[offset(99)] as p99_ingest_lag_ms,

        -- Surfaced rather than hidden: an hour containing recovered trades is
        -- complete, but it is not the same as an hour that never broke.
        countif(is_backfilled)                                  as backfilled_trades,

        -- Negative lag is our clock running behind the exchange's, not an
        -- error. Surfaced as its own measure rather than hidden by abs().
        countif(ingest_lag_ms < 0)                              as negative_lag_rows,

        min(event_time)                                         as first_event_time,
        max(event_time)                                         as last_event_time

    from trades
    group by 1, 2

)

select
    h.product_id,
    h.event_hour,

    h.trades_received,
    h.trade_id_span                                             as trades_expected,
    greatest(h.trade_id_span - h.trades_received, 0)            as trades_missing,

    -- The headline number. 100 means every trade the exchange issued in this
    -- hour is present.
    round(safe_divide(h.trades_received, h.trade_id_span) * 100, 4) as completeness_pct,

    coalesce(r.raw_rows - r.distinct_trades, 0)                 as duplicates_removed,

    h.p50_ingest_lag_ms,
    h.p95_ingest_lag_ms,
    h.p99_ingest_lag_ms,
    h.negative_lag_rows,
    h.backfilled_trades,

    h.first_trade_id,
    h.last_trade_id,
    h.first_event_time,
    h.last_event_time,

    -- SLA verdicts, evaluated here so a dashboard or alert does not have to
    -- re-encode the thresholds from docs/slas.md and drift from them.
    safe_divide(h.trades_received, h.trade_id_span) >= 0.9999   as meets_completeness_sla,
    h.p99_ingest_lag_ms <= 5000                                 as meets_latency_sla,

    h.event_date

from per_hour h
left join raw_counts r
  on h.product_id = r.product_id and h.event_hour = r.event_hour
