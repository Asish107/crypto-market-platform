{#
  Every raw table is declared with require_partition_filter = true, so a query
  without a partition predicate FAILS rather than quietly scanning everything.
  That is a deliberate cost guard, and it means every source query needs this.

  The `_PARTITIONTIME IS NULL` half is not optional. Rows arriving through the
  streaming path sit in an unpartitioned buffer with a NULL _PARTITIONTIME
  until BigQuery commits them to a date partition, which can take minutes.
  Filtering on the date range alone therefore excludes precisely the freshest
  rows - the pipeline looks broken while working perfectly.
#}
{% macro raw_partition_filter(days_back=none) %}
  {%- set days = days_back if days_back is not none else var('lookback_days') -%}
  (
    _PARTITIONTIME IS NULL
    OR _PARTITIONTIME >= TIMESTAMP_SUB(
         TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY), INTERVAL {{ days }} DAY)
  )
{% endmacro %}
