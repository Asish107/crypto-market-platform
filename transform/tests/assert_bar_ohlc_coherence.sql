/*
  The OHLC invariant: low <= open, close <= high, always, by definition.

  A violation means the bar aggregation is wrong - almost always an ordering
  bug where `open` was taken from the wrong trade. The resulting bars look
  entirely normal on a chart, which is what makes this worth asserting rather
  than eyeballing.
*/

select
    product_id,
    bar_start,
    open, high, low, close
from {{ ref('fct_bars_1m') }}
where low > open
   or low > close
   or high < open
   or high < close
   or low > high
