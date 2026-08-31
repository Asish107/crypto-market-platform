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
  Realised volatility per product-hour, by three estimators.

  Why three: they use different information and disagree in informative ways.

    close-to-close  - stdev of log returns. The textbook measure, and the
                      weakest: it sees only the endpoint of each minute and is
                      blind to everything that happened inside it.

    Parkinson       - uses the high-low RANGE. Roughly 5x more efficient than
                      close-to-close for the same sample, because a bar that
                      opened and closed flat after a violent swing is not
                      quiet, and close-to-close says it was.

    Garman-Klass    - uses the full OHLC. More efficient still, but assumes no
                      overnight jumps - which suits crypto, since it never
                      closes.

  A large gap between Parkinson and close-to-close means intrabar movement is
  being missed, which is itself the interesting signal.

  ANNUALISATION: crypto trades continuously, so the year is 365 * 24 * 60
  minutes, not the 252 trading days used for equities. Getting this wrong
  scales every number by ~2.4x and the result still looks plausible.
*/

with bars as (

    select
        product_id,
        bar_start,
        open, high, low, close,
        timestamp_trunc(bar_start, HOUR) as window_start,
        event_date
    from {{ ref('fct_bars_1m') }}

    {% if is_incremental() %}
      where event_date >= date_sub(current_date(), interval {{ var('lookback_days') }} day)
    {% endif %}

),

returns as (

    select
        *,
        -- Log returns, not simple returns: they are additive across time,
        -- which is what makes the sum-of-squares below meaningful.
        ln(safe_divide(cast(close as float64),
                       lag(cast(close as float64)) over w))     as log_return,
        ln(safe_divide(cast(high as float64),
                       cast(low as float64)))                   as log_hl,
        ln(safe_divide(cast(close as float64),
                       cast(open as float64)))                  as log_co
    from bars
    window w as (partition by product_id order by bar_start)

),

by_window as (

    select
        product_id,
        window_start,
        count(*)                                                as bar_count,
        stddev_samp(log_return)                                  as sigma_cc,
        avg(pow(log_hl, 2))                                      as mean_sq_hl,
        avg(0.5 * pow(log_hl, 2) - (2 * ln(2) - 1) * pow(log_co, 2)) as gk_term,
        any_value(event_date)                                    as event_date
    from returns
    group by 1, 2

)

select
    product_id,
    window_start,
    timestamp_add(window_start, interval 1 hour)                 as window_end,
    bar_count,

    -- Per-minute volatilities
    sigma_cc                                                     as vol_close_to_close,
    sqrt(safe_divide(mean_sq_hl, 4 * ln(2)))                     as vol_parkinson,
    sqrt(greatest(gk_term, 0))                                   as vol_garman_klass,

    -- Annualised, on a 365-day continuously-trading year.
    sigma_cc * sqrt({{ var('minutes_per_year') }})               as vol_close_to_close_annualised,
    sqrt(safe_divide(mean_sq_hl, 4 * ln(2))) * sqrt({{ var('minutes_per_year') }})
                                                                 as vol_parkinson_annualised,

    event_date

from by_window
