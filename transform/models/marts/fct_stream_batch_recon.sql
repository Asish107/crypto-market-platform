{{
  config(
    materialized     = 'table',
    schema           = 'marts',
    on_schema_change = 'fail'
  )
}}

/*
  Where streaming and batch disagree, and by how much.

  Anyone can write a streaming job. The artefact worth having is a precise,
  queryable answer to "do the two paths agree, and when they don't, why" -
  because in a lambda architecture that question decides whether you can trust
  either number.

  Both sides compute 1-minute bars from the SAME source data:

    batch     - dbt, over trades that landed in BigQuery, recomputing whole
                partitions with no notion of lateness. It sees everything that
                ever arrived.
    streaming - Dataflow, fixed 1-minute windows on EXCHANGE event time, with
                30 seconds of allowed lateness. It sees what arrived in time.

  So the expected divergence is one-directional: streaming <= batch. A trade
  whose event time falls in a window the watermark has passed, arriving later
  than the grace period, is dropped by streaming and silently kept by batch.

  Divergence in the OTHER direction (streaming > batch) would mean something
  is genuinely broken - most likely double counting from accumulating panes.
  It is called out separately for exactly that reason.
*/

with streaming_panes as (

    select
        product_id,
        bar_start,
        open, high, low, close,
        volume, trade_count, vwap,
        first_trade_id, last_trade_id,
        pane_index,
        is_final_pane,
        written_at
    from {{ source('curated', 'bars_1m_stream') }}

),

-- Accumulating panes restate the whole window, so only the last one is the
-- streaming job's final answer. Summing panes would double count badly.
streaming_final as (

    select * except (rn)
    from (
        select
            *,
            row_number() over (
                partition by product_id, bar_start
                order by pane_index desc, written_at desc
            ) as rn
        from streaming_panes
    )
    where rn = 1

),

pane_activity as (

    select
        product_id,
        bar_start,
        count(*)              as pane_count,
        max(pane_index)       as final_pane_index
    from streaming_panes
    group by 1, 2

),

-- The first window a burst run sees is almost always PARTIAL: the job starts
-- mid-minute and only ever sees trades from that point on. Batch sees the
-- whole minute. Attributing that to late-data semantics would be wrong, and
-- wrong attribution is worse than none - it makes the streaming model look
-- lossier than it is.
-- The batch path only knows about minutes it has actually built. Streaming is
-- continuous, so the most recent window or two legitimately exist only in
-- streaming until the next dbt run. Calling that "streaming over-counted"
-- would be a false alarm on the one condition that genuinely means broken.
batch_frontier as (

    select
        product_id,
        max(bar_start) as latest_built_window
    from {{ ref('fct_bars_1m') }}
    group by 1

),

job_boundaries as (

    select
        product_id,
        min(bar_start) as first_window,
        max(bar_start) as last_window
    from streaming_final
    group by 1

),

batch as (

    select
        product_id,
        bar_start,
        open, high, low, close,
        volume, trade_count, vwap,
        first_trade_id, last_trade_id
    from {{ ref('fct_bars_1m') }}

),

joined as (

    select
        coalesce(s.product_id, b.product_id)          as product_id,
        coalesce(s.bar_start, b.bar_start)            as bar_start,

        s.trade_count                                 as stream_trade_count,
        b.trade_count                                 as batch_trade_count,
        s.volume                                      as stream_volume,
        b.volume                                      as batch_volume,
        s.close                                       as stream_close,
        b.close                                       as batch_close,
        s.vwap                                        as stream_vwap,
        b.vwap                                        as batch_vwap,

        p.pane_count,
        p.final_pane_index,

        s.product_id is not null                      as in_stream,
        b.product_id is not null                      as in_batch,

        coalesce(s.bar_start, b.bar_start) = j.first_window as is_first_window,
        coalesce(s.bar_start, b.bar_start) = j.last_window  as is_last_window,
        coalesce(s.bar_start, b.bar_start) >= f.latest_built_window as at_batch_frontier

    from streaming_final s
    full outer join batch b
      on s.product_id = b.product_id and s.bar_start = b.bar_start
    left join pane_activity p
      on p.product_id = s.product_id and p.bar_start = s.bar_start
    left join job_boundaries j
      on j.product_id = coalesce(s.product_id, b.product_id)
    left join batch_frontier f
      on f.product_id = coalesce(s.product_id, b.product_id)

)

select
    product_id,
    bar_start,

    in_stream,
    in_batch,

    stream_trade_count,
    batch_trade_count,
    coalesce(batch_trade_count, 0) - coalesce(stream_trade_count, 0) as trade_count_diff,

    stream_volume,
    batch_volume,
    coalesce(batch_volume, 0) - coalesce(stream_volume, 0)           as volume_diff,

    stream_close,
    batch_close,
    stream_vwap,
    batch_vwap,

    pane_count,
    final_pane_index,

    is_first_window,
    is_last_window,
    at_batch_frontier,

    -- Did the streaming job restate this window after first firing? A pane
    -- count above 1 IS late data, caught inside the allowed lateness.
    coalesce(pane_count, 0) > 1                                      as was_restated,

    stream_trade_count = batch_trade_count                           as counts_agree,

    -- The headline: agreement on the numbers anyone would actually use.
    (
        stream_trade_count = batch_trade_count
        and abs(coalesce(stream_volume, 0) - coalesce(batch_volume, 0)) < 0.00000001
        and stream_close = batch_close
    )                                                                as bars_agree,

    -- Why they differ, in the language of the streaming model rather than as
    -- an unexplained delta.
    case
        when not in_stream and in_batch
            then 'outside_run_window: the burst job was not running for this minute'
        -- Frontier check FIRST. Streaming is continuous and batch is
        -- scheduled, so the newest window existing only in streaming is
        -- normal. Checking "broken" before "expected" is how a reconciliation
        -- report cries wolf and stops being read.
        when in_stream and not in_batch and at_batch_frontier
            then 'batch_not_yet_built: streaming is ahead of the last dbt run'
        when in_stream and not in_batch
            then 'missing_from_batch: BROKEN - streaming saw a window batch has no trades for'

        -- Attribution order matters. A partial first or last window is an
        -- artefact of when the job was started and stopped, NOT a property of
        -- the streaming model, and lumping it in with late data would
        -- overstate how lossy streaming is.
        when is_first_window and stream_trade_count < batch_trade_count
            then 'partial_window_at_startup: job began mid-minute'
        when is_last_window and stream_trade_count < batch_trade_count
            then 'partial_window_at_shutdown: job was drained mid-minute'

        when stream_trade_count < batch_trade_count
            then 'late_data_dropped: trades arrived after the 30s allowed lateness expired'
        -- Streaming is continuous; batch runs on a schedule. The newest
        -- window or two legitimately exist only in streaming until the next
        -- dbt run, and that is not over-counting.
        when at_batch_frontier and stream_trade_count > batch_trade_count
            then 'batch_not_yet_built: streaming is ahead of the last dbt run'
        when stream_trade_count > batch_trade_count
            then 'over_count: BROKEN - likely accumulating panes summed instead of taking the final one'
        else 'agree'
    end                                                              as divergence_reason,

    date(bar_start)                                                  as event_date

from joined
