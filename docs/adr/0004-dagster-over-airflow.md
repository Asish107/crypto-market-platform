# ADR 0004: Dagster over Airflow

**Status:** accepted · **Date:** 2026-08-31

## Context

The platform needs scheduled dbt runs, a freshness check on the raw feed, and a
parameterised backfill. Candidates: Cloud Composer (managed Airflow),
self-managed Airflow, or Dagster on Cloud Run.

## Decision

Dagster, deployed as a code location on Cloud Run.

## Rationale

- **Cost, decisively.** Cloud Composer's smallest environment is ~$300/month
  against a ~$34/month platform. It would be an order of magnitude more
  expensive than everything it orchestrates.
- **Assets, not tasks.** Dagster models software-defined assets, which map 1:1
  onto dbt models. The lineage graph *is* the dbt DAG rather than a
  hand-maintained drawing of it that drifts the first time someone adds a model
  and forgets the DAG file.
- **Local development is real.** `dagster dev` runs the same definitions that
  run in production. Airflow's local story involves a scheduler, a webserver
  and a metadata database before you can see whether your DAG parses.

## What we give up

- **Operator ecosystem.** Airflow has a provider for everything. We need
  BigQuery, dbt and Pub/Sub, all of which Dagster covers directly.
- **Hiring familiarity.** More engineers know Airflow. The concepts transfer.
- **We run it ourselves.** Composer would be managed; this is a Cloud Run
  service plus a Cloud SQL instance we patch. At this scale that is a couple of
  hours a year, and the $266/month difference buys a lot of hours.

## A verification note

Executing dbt through Dagster fails on macOS with SIGKILL while the identical
`dbt build` succeeds standalone — memory pressure in the forked subprocess. It
runs correctly on Linux, verified in Docker with 17/17 tests passing, which is
the deployment target. Worth knowing before losing an afternoon to it locally.
