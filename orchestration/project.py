"""Locating the dbt project, and its manifest.

Dagster turns each dbt model into an asset by reading dbt's manifest.json. In
development that manifest is regenerated on the fly so a model added seconds
ago shows up; in production it is built once at image build time, because
running `dbt parse` on every code load makes deploys slow and makes the asset
graph depend on a warehouse connection being available at import.
"""

from __future__ import annotations

import os
from pathlib import Path

from dagster_dbt import DbtProject

DBT_PROJECT_DIR = Path(__file__).joinpath("..", "..", "transform").resolve()

# profiles.yml lives inside the project dir, which DbtProject uses by default;
# it takes no profiles_dir argument.
dbt_project = DbtProject(
    project_dir=DBT_PROJECT_DIR,
    target=os.environ.get("DBT_TARGET", "dev"),
)

# No-op when a manifest already exists and is current.
dbt_project.prepare_if_dev()
