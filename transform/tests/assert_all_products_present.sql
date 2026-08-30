/*
  Every tracked product must actually appear in the mart.

  This test exists because of a real bug: a `min_real_trade_id: 1e9` filter,
  written to exclude two synthetic rows and calibrated by looking only at BTC,
  silently deleted ETH-USD and SOL-USD in full. Coinbase trade id counters are
  PER PRODUCT - BTC is at ~1.08e9, ETH at ~839M, SOL at ~351M - so the
  threshold was above both.

  Every other test passed. BTC's contiguity was perfect, prices were in range,
  nothing was duplicated. Absence is invisible to tests that only inspect the
  rows that are there.

  Warn rather than error on a quiet product: a genuinely illiquid pair can go
  minutes without a trade, and paging someone for that is how alerts get muted.
*/

{{ config(severity = 'warn') }}

with expected as (
    select product_id
    from unnest({{ var('tracked_products') }}) as product_id
),

actual as (
    select distinct product_id
    from {{ ref('fct_trades') }}
    where event_date >= date_sub(current_date(), interval 1 day)
)

select e.product_id as missing_product
from expected e
left join actual a using (product_id)
where a.product_id is null
