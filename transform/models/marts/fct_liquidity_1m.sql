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
  What it actually costs to trade, per product per minute.

  Bars tell you where the price went. They say nothing about whether you could
  have traded there. A market can print a tight last price with almost nothing
  resting behind it, and the first real order moves it several percent.

  Three measures, in increasing order of usefulness:

    spread_bps  - the cost of an infinitesimal round trip. Comparable across
                  products in a way an absolute spread is not: $1 on BTC and
                  $1 on SOL are entirely different things.

    depth_Nbps  - total size resting within N basis points of the mid. This is
                  the honest liquidity measure: top-of-book size tells you
                  almost nothing about moving real volume.

    book_imbalance - (bid - ask) / (bid + ask) depth, in [-1, 1]. Positive
                  means more resting demand than supply, which is a
                  short-horizon directional signal.
*/

with book as (

    select * from {{ ref('int_book_state_1m') }}

    {% if is_incremental() %}
      where event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    {% endif %}

),

top_of_book as (

    select
        product_id,
        event_minute,
        event_date,
        max(if(side = 'buy',  price, null))  as best_bid,
        min(if(side = 'sell', price, null))  as best_ask
    from book
    group by 1, 2, 3

),

with_mid as (

    select
        *,
        (best_bid + best_ask) / 2                            as mid,
        best_ask - best_bid                                  as spread
    from top_of_book
    where best_bid is not null and best_ask is not null

),

depth as (

    select
        b.product_id,
        b.event_minute,

        -- Depth bands. Computed from the reconstructed book rather than from
        -- top-of-book size, because the question "what does $1M cost me" is
        -- answered by the levels, not the touch.
        sum(if(b.side = 'buy'  and b.price >= m.mid * (1 - 0.0005), b.size, 0)) as bid_depth_5bps,
        sum(if(b.side = 'sell' and b.price <= m.mid * (1 + 0.0005), b.size, 0)) as ask_depth_5bps,
        sum(if(b.side = 'buy'  and b.price >= m.mid * (1 - 0.0010), b.size, 0)) as bid_depth_10bps,
        sum(if(b.side = 'sell' and b.price <= m.mid * (1 + 0.0010), b.size, 0)) as ask_depth_10bps,
        sum(if(b.side = 'buy'  and b.price >= m.mid * (1 - 0.0025), b.size, 0)) as bid_depth_25bps,
        sum(if(b.side = 'sell' and b.price <= m.mid * (1 + 0.0025), b.size, 0)) as ask_depth_25bps,
        count(*)                                                                as book_levels

    from book b
    join with_mid m
      on b.product_id = m.product_id and b.event_minute = m.event_minute
    group by 1, 2

)

select
    m.product_id,
    m.event_minute                                           as bar_start,

    m.best_bid,
    m.best_ask,
    m.mid,
    m.spread,
    safe_divide(m.spread, m.mid) * 10000                     as spread_bps,

    d.bid_depth_5bps,
    d.ask_depth_5bps,
    d.bid_depth_10bps,
    d.ask_depth_10bps,
    d.bid_depth_25bps,
    d.ask_depth_25bps,

    -- Notional depth: what the resting size is actually worth, which is what
    -- a trader sizing an order cares about.
    d.bid_depth_25bps * m.mid                                as bid_depth_25bps_notional,
    d.ask_depth_25bps * m.mid                                as ask_depth_25bps_notional,

    safe_divide(
        d.bid_depth_25bps - d.ask_depth_25bps,
        d.bid_depth_25bps + d.ask_depth_25bps
    )                                                        as book_imbalance,

    d.book_levels,
    m.event_date

from with_mid m
join depth d
  on m.product_id = d.product_id and m.event_minute = d.event_minute
