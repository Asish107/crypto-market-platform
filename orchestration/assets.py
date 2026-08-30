"""Assets.

Every dbt model becomes a Dagster asset, so the lineage graph in the UI is the
dbt DAG rather than a hand-maintained drawing of it that drifts. That 1:1
mapping is most of the reason for choosing Dagster here - see ADR 0004.
"""

# NO `from __future__ import annotations` in this module. It turns annotations
# into strings, and Dagster inspects the `context` parameter's type at runtime
# to decide what to pass in - it fails with "Cannot annotate context parameter
# with type AssetExecutionContext", which is a confusing way to say the hint
# was a string by the time it looked.
from collections.abc import Iterator, Mapping
from typing import Any

from dagster import AssetExecutionContext, AssetKey, Output
from dagster_dbt import DagsterDbtTranslator, DbtCliResource, dbt_assets

from orchestration.project import dbt_project


class MarketDbtTranslator(DagsterDbtTranslator):
    """Names the raw Pub/Sub tables as external assets.

    Without this, dbt sources appear as bare table names disconnected from
    anything, and the graph starts at staging - hiding the fact that everything
    depends on the ingest consumer still running.
    """

    def get_asset_key(self, dbt_resource_props: Mapping[str, Any]) -> AssetKey:
        if dbt_resource_props["resource_type"] == "source":
            return AssetKey(["raw", dbt_resource_props["name"]])
        return super().get_asset_key(dbt_resource_props)

    def get_group_name(self, dbt_resource_props: Mapping[str, Any]) -> "str | None":
        # Group by dbt layer so the UI mirrors models/ on disk.
        path = dbt_resource_props["fqn"]
        return path[1] if len(path) > 2 else "market"


@dbt_assets(
    manifest=dbt_project.manifest_path,
    dagster_dbt_translator=MarketDbtTranslator(),
)
def market_dbt_assets(context: AssetExecutionContext, dbt: DbtCliResource) -> Iterator[Output]:
    """Build and test every dbt model.

    `dbt build` rather than `run` then `test`: build interleaves them, so a
    model whose tests fail does NOT have its children built on top of it. With
    run-then-test, bad data has already propagated through the whole DAG by the
    time the tests report it.
    """
    yield from dbt.cli(["build"], context=context).stream()
