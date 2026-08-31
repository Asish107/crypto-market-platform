/*
  bid < ask. Always. A crossed book is never a market condition - it means the
  reconstruction is broken.

  This test has already earned its place. Two separate bugs produced crossed
  books during development:

    1. a carry-forward that ordered by a column constant within its window,
       so the "latest" state of a price level was chosen arbitrarily

    2. mixing two clocks - snapshots stamped with LOCAL receive time,
       l2updates with the EXCHANGE's - which, given our clock runs ~40ms
       behind, dropped exactly the removals that clear a crossed level

  Neither looked wrong anywhere else. Spreads were plausible, depths were
  plausible, nothing else failed. This invariant is the only thing that
  catches them, which is also why the consumer checks it in memory.
*/

select
    product_id,
    bar_start,
    best_bid,
    best_ask,
    spread
from {{ ref('fct_liquidity_1m') }}
where best_bid >= best_ask
   or spread <= 0
