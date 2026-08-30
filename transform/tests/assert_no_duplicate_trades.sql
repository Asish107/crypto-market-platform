/*
  Dedupe correctness.

  The exchange replays trades on reconnect, so duplicates genuinely arrive.
  stg_trades removes them with a window function keeping the earliest arrival.
  If that logic breaks, volume and trade counts inflate silently - nothing
  about a doubled volume figure looks wrong.
*/

select
    trade_id,
    product_id,
    count(*) as occurrences
from {{ ref('fct_trades') }}
group by 1, 2
having count(*) > 1
