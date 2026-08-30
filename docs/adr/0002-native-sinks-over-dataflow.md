# ADR 0002: Native Pub/Sub sinks over Dataflow in the hot path

**Status:** accepted · **Date:** 2026-08-30

## Context

Raw messages must land in two places: an immutable Avro lake on GCS, and a
BigQuery table for low-latency querying. The conventional GCP reference
architecture puts a Dataflow streaming job in between.

## Decision

Use Pub/Sub's **native GCS subscription** and **native BigQuery subscription**.
No Dataflow in the ingest path. Dataflow is used only in Phase 6, for windowed
streaming aggregation, where the computation genuinely needs a stream processor.

## Rationale

The Dataflow job in the reference architecture would do exactly one thing:
serialize a message and write it somewhere. That is not a computation; it is
plumbing, and Pub/Sub already has it built in.

| | Native sinks | Dataflow |
|---|---|---|
| Cost | $0 (no compute) | ~$70/mo for 1 always-on n1-standard-1 worker |
| Things that can break | subscription IAM | worker pool, autoscaling, job graph updates, drain/cancel semantics, SDK upgrades |
| Latency to BigQuery | seconds | seconds |
| Custom per-message logic | none possible | arbitrary |

We need no custom per-message logic in this path — the consumer has already
done the parsing, sequence tracking and enrichment before publishing. Paying
$70/mo and taking on a job graph to serialize bytes would be
résumé-driven architecture.

## What we give up

- **No in-flight transformation.** Anything the raw layer needs must be done by
  the consumer before publish, or by dbt after landing. This is the right
  split anyway: transformation belongs in a tested, version-controlled dbt
  model, not in a streaming job nobody can reproduce locally.
- **Lake partitioning is much coarser than sketched, and this is forced.**
  Pub/Sub's filename grammar requires all six datetime matchers
  (`YYYY MM DD hh mm ss`), permits each exactly once, and allows no literal
  text beyond `-` `_` `:` `/`. BigQuery hive partitioning requires `key=value`
  directories. The only free text available is the static `filename_prefix`.

  Therefore the lake gets **exactly one** hive level, and it has to be the
  useful one:

  ```
  trades/dt=2026-08-30/17_56_25_f3b183.avro
  ```

  Hour lives in the filename, not a partition key. Product is a column, not a
  path segment. Neither costs anything real: every downstream model partitions
  by DAY, so hour-level pruning was never going to be used, and 24× the
  partitions would make BigQuery's metadata layer slower rather than faster.
  Product filtering uses clustering, which prunes just as effectively.

  The alternative that preserves the original layout is a Dataflow job writing
  the files itself — which is precisely the ~$70/mo this ADR declines to spend.
- **Schema changes are more rigid.** The BQ subscription requires the table
  schema to match the topic's Avro schema. `drop_unknown_fields = false` makes
  that mismatch loud rather than silent, and the raw table DDL is kept in
  Terraform beside the `.avsc` so the two are reviewed together.
