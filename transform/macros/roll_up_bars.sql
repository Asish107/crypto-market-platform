{#
  Roll 1-minute bars into a coarser interval.

  Rolled up, never recomputed from ticks. Two reasons:

  1. Cost - the tick tape is orders of magnitude larger than the bars, and
     recomputing 1h bars from ticks rescans all of it.
  2. Consistency - if 1h bars were computed independently, the sum of the 1m
     bars inside an hour could legitimately disagree with the 1h bar after any
     late-arriving data, and reconciling that is a bad afternoon.

  Note OHLC does NOT aggregate uniformly: high/low are max/min, but open and
  close must come from the FIRST and LAST sub-bar. Taking min(open) would be
  quietly, plausibly wrong.
#}
{% macro roll_up_bars(interval_expr) %}

with base as (

    select
        *,
        {{ interval_expr }} as window_start
    from {{ ref('fct_bars_1m') }}

    {% if is_incremental() %}
      where event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    {% endif %}

),

ordered as (

    select
        *,
        row_number() over (partition by product_id, window_start order by bar_start asc)  as seq_asc,
        row_number() over (partition by product_id, window_start order by bar_start desc) as seq_desc
    from base

)

select
    product_id,
    window_start                                          as bar_start,

    max(if(seq_asc = 1, open, null))                      as open,
    max(high)                                             as high,
    min(low)                                              as low,
    max(if(seq_desc = 1, close, null))                    as close,

    sum(volume)                                           as volume,
    sum(quote_volume)                                     as quote_volume,
    sum(trade_count)                                      as trade_count,

    -- Re-weighted across sub-bars. Averaging the sub-VWAPs would weight a
    -- one-trade minute the same as a thousand-trade minute.
    safe_divide(sum(quote_volume), sum(volume))           as vwap,

    sum(buy_volume)                                       as buy_volume,
    sum(sell_volume)                                      as sell_volume,
    safe_divide(sum(buy_volume) - sum(sell_volume), sum(volume)) as volume_imbalance,

    count(*)                                              as source_bar_count,
    date(window_start)                                    as event_date

from ordered
group by product_id, window_start

{% endmacro %}
