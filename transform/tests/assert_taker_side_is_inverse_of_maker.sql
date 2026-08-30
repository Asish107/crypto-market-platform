/*
  The classification invariant.

  `side` is the maker's side; `taker_side` is the aggressor's. They must always
  be opposites - a trade has exactly one of each. Inverting this would flip
  every buy/sell volume imbalance downstream, and the resulting numbers look
  entirely plausible, which is what makes it worth a test.
*/

select
    trade_id,
    product_id,
    side,
    taker_side
from {{ ref('fct_trades') }}
where side = taker_side
   or taker_side is null
