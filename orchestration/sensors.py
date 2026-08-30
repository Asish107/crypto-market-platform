"""Sensors and schedules.

The freshness sensor is the piece that matters. A pipeline that fails loudly is
easy; a pipeline that silently stops receiving data looks identical to a quiet
market, and the only way to tell them apart is to assert that new data should
have arrived by now.
"""

from __future__ import annotations

from dagster import (
    AssetSelection,
    DefaultSensorStatus,
    RunRequest,
    ScheduleDefinition,
    SensorEvaluationContext,
    SensorResult,
    SkipReason,
    build_schedule_from_partitioned_job,
    define_asset_job,
    sensor,
)

from orchestration.assets import market_dbt_assets

# Hourly is deliberate. Nothing downstream needs sub-minute freshness: bars are
# minute-grained but nobody trades off this warehouse, and running dbt every
# minute would cost more in BigQuery than the rest of the platform combined.
# The SLA in docs/slas.md commits to 15 minutes for fct_bars_1m, which an
# hourly cadence does NOT meet - that is a known gap, resolved either by
# tightening this schedule or relaxing the SLA. Writing it down beats
# discovering it in a review.
dbt_job = define_asset_job(
    name="dbt_build",
    selection=AssetSelection.assets(market_dbt_assets),
    description="Build and test every dbt model.",
)

hourly_dbt_schedule = ScheduleDefinition(
    job=dbt_job,
    cron_schedule="7 * * * *",
    # Seven past the hour, not on the hour: every scheduled job in the world
    # fires at :00, and BigQuery slot contention is real on a shared project.
    execution_timezone="UTC",
    name="hourly_dbt_build",
)

FRESHNESS_LIMIT_MINUTES = 5


@sensor(
    job=dbt_job,
    minimum_interval_seconds=60,
    default_status=DefaultSensorStatus.STOPPED,
    description="Alerts when the raw feed goes quiet.",
)
def feed_freshness_sensor(context: SensorEvaluationContext) -> SensorResult | SkipReason:
    """Fail loudly if no trade has landed in FRESHNESS_LIMIT_MINUTES.

    Deliberately queries `raw` rather than a mart: this must detect the
    consumer dying, which would leave every mart perfectly valid and simply
    frozen in time.
    """
    from google.cloud import bigquery

    client = bigquery.Client()
    rows = list(
        client.query(
            """
            SELECT TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), MAX(publish_time), MINUTE) AS staleness_min
            FROM `dataengproj01.raw.trades_stream`
            WHERE _PARTITIONTIME IS NULL
               OR _PARTITIONTIME >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
            """
        ).result()
    )

    staleness = rows[0].staleness_min if rows and rows[0].staleness_min is not None else None

    if staleness is None:
        return SkipReason("No trades in the last 24h - the feed has never run or is long dead.")

    if staleness > FRESHNESS_LIMIT_MINUTES:
        context.log.error(f"Feed stale: no trade published in {staleness} minutes")
        return SkipReason(f"Feed stale by {staleness} min - not running dbt on frozen data.")

    return SensorResult(run_requests=[RunRequest(run_key=f"fresh-{staleness}")])


__all__ = [
    "dbt_job",
    "hourly_dbt_schedule",
    "feed_freshness_sensor",
    "build_schedule_from_partitioned_job",
]
