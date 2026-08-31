{{ config(materialized = 'table', schema = 'intermediate') }}

/*
  Book state at each minute boundary, reconstructed from a snapshot plus every
  delta that followed it.

  THE HARD PART: the feed gives absolute state exactly once (the snapshot),
  then only changes. To know the book at 21:47:00 you need the snapshot plus
  every delta up to that instant, with a size of zero meaning "this level is
  gone" rather than "this level holds zero".

  PRUNING: the full book is ~44,000 price levels per product, and carrying
  every level forward across every minute is O(levels x minutes) - about 63M
  rows per product-day, for information nobody queries. Levels far from the
  mid never touch a spread or a depth-at-25bps figure.

  So the book is pruned to +/- 1% of the reference mid before reconstruction.
  That is 40x wider than the widest depth band we publish (25bps), so it
  cannot affect any published number, and it keeps this model tractable.

  A consequence worth stating: this model cannot answer questions about deep
  book structure. If that is ever needed, it needs a different design - most
  likely incremental state carried between runs rather than recomputed.
*/

-- CLOCK: everything here is ordered by ingest_time (local receive), never
-- event_time. Two different clocks feed event_time:
--
--   l2update - the EXCHANGE's timestamp
--   snapshot - our LOCAL receive time, because Coinbase sends no timestamp
--              on a snapshot
--
-- Our clock runs tens of milliseconds behind the exchange's (measured: p50
-- ingest lag of -35ms). So an update that genuinely arrived AFTER a snapshot
-- can carry an earlier event_time, and ordering by it drops precisely the
-- removals that clear a crossed level. That produced a book with the bid
-- above the ask - impossible in any real market.
--
-- Arrival order is also the CORRECT order here: it is the order the exchange
-- sent them and the order the consumer applied them.
with events as (

    select
        product_id,
        side,
        price,
        size,
        event_type,
        ingest_time                             as state_time,
        event_time,
        change_index,
        timestamp_trunc(ingest_time, MINUTE)    as event_minute
    from {{ ref('stg_l2_events') }}

),

-- Each snapshot RESETS the book. Only events at or after the most recent one
-- are valid: applying deltas across a reconnect corrupts state silently.
latest_snapshot as (

    select
        product_id,
        max(state_time) as snapshot_time
    from events
    where event_type = 'snapshot'
    group by 1

),

reference_mid as (

    select
        e.product_id,
        (min(if(e.side = 'sell', e.price, null))
         + max(if(e.side = 'buy', e.price, null))) / 2 as mid
    from events e
    join latest_snapshot s
      on e.product_id = s.product_id and e.state_time = s.snapshot_time
    where e.event_type = 'snapshot' and e.size > 0
    group by 1

),

relevant as (

    select e.*
    from events e
    join latest_snapshot s on e.product_id = s.product_id
    join reference_mid m   on e.product_id = m.product_id
    where e.state_time >= s.snapshot_time
      and abs(e.price - m.mid) <= m.mid * 0.01

),

-- Last state of each price level within each minute. A level touched five
-- times in a minute is only interesting at the end of it.
level_minute as (

    select
        product_id,
        side,
        price,
        event_minute,
        -- THE ORDERING, and it needs all three parts:
        --
        --   1. snapshot first  - it is absolute state; every delta follows it
        --   2. exchange time   - the true order of updates. Local receive
        --                        time cannot order them: Pub/Sub batches, so
        --                        several messages routinely share one receive
        --                        millisecond, and a removal at .450 arrived in
        --                        the same millisecond as a re-add at .390
        --   3. change_index    - position within a single message, where the
        --                        same level can be removed and re-added
        --
        -- Getting any of the three wrong leaves a stale level in the book and
        -- produces an ask BELOW the bid.
        array_agg(size
            order by
                case when event_type = 'snapshot' then 0 else 1 end desc,
                event_time desc,
                change_index desc
            limit 1)[offset(0)] as size
    from relevant
    group by 1, 2, 3, 4

),

minute_grid as (
    select distinct product_id, event_minute from relevant
),

-- Carry each level forward: a level not mentioned in a minute keeps whatever
-- size it last had. This is the "as-of" fill that makes the state complete.
--
-- The join emits EVERY prior state of a level for each grid minute, so the
-- pick has to be explicit. An earlier version used
--   last_value(size) over (partition by ... order by g.event_minute)
-- which orders by a column that is constant within each join group, making
-- the choice arbitrary. It produced a CROSSED book - bid above ask - which is
-- the one thing a book can never be, and is why assert_no_crossed_book exists.
carried as (

    select
        g.product_id,
        g.event_minute,
        l.side,
        l.price,
        l.size
    from minute_grid g
    join level_minute l
      on  g.product_id = l.product_id
      and l.event_minute <= g.event_minute
    -- Latest state of this level at or before this minute. Explicitly ordered
    -- by the LEVEL's minute, which is what actually varies.
    qualify row_number() over (
        partition by g.product_id, g.event_minute, l.side, l.price
        order by l.event_minute desc
    ) = 1

)

select
    product_id,
    event_minute,
    side,
    price,
    size,
    date(event_minute) as event_date
from carried
-- Size zero means the level was removed. Keeping it would leave phantom
-- liquidity in the book forever, and top-of-book would stick to a price
-- nobody is quoting.
where size > 0
