/*
  Bars must account for every trade, exactly once.

  Reconciles the bars back to the tick tape they were built from: total volume
  and trade count per product-day must match fct_trades. A GROUP BY that drops
  or double-counts rows is otherwise invisible - the bars still look like bars.

  Uses a tolerance on volume because NUMERIC summation order can differ by a
  few ulps between the two aggregations; trade_count must match exactly.
*/

with from_bars as (
    select
        product_id,
        event_date,
        sum(volume)       as volume,
        sum(trade_count)  as trade_count
    from {{ ref('fct_bars_1m') }}
    group by 1, 2
),

from_trades as (
    select
        product_id,
        event_date,
        sum(size)  as volume,
        count(*)   as trade_count
    from {{ ref('fct_trades') }}
    group by 1, 2
)

select
    b.product_id,
    b.event_date,
    b.volume       as bar_volume,
    t.volume       as trade_volume,
    b.trade_count  as bar_trades,
    t.trade_count  as tape_trades
from from_bars b
full outer join from_trades t
  on b.product_id = t.product_id and b.event_date = t.event_date
where b.trade_count is distinct from t.trade_count
   or abs(coalesce(b.volume, 0) - coalesce(t.volume, 0)) > 0.00000001
