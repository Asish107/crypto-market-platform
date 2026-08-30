"""Dagster entry point.

Run the UI locally:

    GCP_PROJECT=dataengproj01 .venv/bin/dagster dev -m orchestration.definitions
"""

from __future__ import annotations

from dagster import Definitions
from dagster_dbt import DbtCliResource

from orchestration.assets import market_dbt_assets
from orchestration.project import dbt_project
from orchestration.sensors import dbt_job, feed_freshness_sensor, hourly_dbt_schedule

defs = Definitions(
    assets=[market_dbt_assets],
    jobs=[dbt_job],
    schedules=[hourly_dbt_schedule],
    sensors=[feed_freshness_sensor],
    resources={
        "dbt": DbtCliResource(
            project_dir=dbt_project,
            profiles_dir=str(dbt_project.project_dir),
        ),
    },
)
