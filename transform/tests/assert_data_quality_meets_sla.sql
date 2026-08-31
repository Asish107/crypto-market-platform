/*
  The SLA in docs/slas.md, enforced rather than aspirational.

  Warns rather than errors: a completeness dip is a fact about the market data,
  not a broken build, and failing the build would block every downstream model
  from refreshing at exactly the moment you most want to look at them.

  Excludes the current hour, which is legitimately partial.
*/

{{ config(severity = 'warn') }}

select
    product_id,
    event_hour,
    trades_received,
    trades_missing,
    completeness_pct,
    p99_ingest_lag_ms
from {{ ref('fct_data_quality') }}
where event_hour < timestamp_trunc(current_timestamp(), HOUR)
  and (not meets_completeness_sla or not meets_latency_sla)
