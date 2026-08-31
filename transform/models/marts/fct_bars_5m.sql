{{
  config(
    materialized         = 'incremental',
    incremental_strategy = 'insert_overwrite',
    partition_by         = {'field': 'event_date', 'data_type': 'date'},
    cluster_by           = ['product_id'],
    on_schema_change     = 'fail'
  )
}}

{{ roll_up_bars("timestamp_trunc(bar_start, MINUTE) - interval mod(extract(minute from bar_start), 5) minute") }}
