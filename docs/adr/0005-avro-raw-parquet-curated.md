# ADR 0005: Avro in the lake, columnar in the warehouse

**Status:** accepted · **Date:** 2026-08-31

## Context

The raw lake needs a file format. The obvious candidates are Avro (row-oriented)
and Parquet (columnar).

## Decision

Avro in the lake. Columnar storage appears only inside BigQuery, which manages
its own format.

## Rationale

- **Pub/Sub's native GCS sink writes Avro.** Choosing Parquet would mean
  inserting a compute step purely to transcode — reversing ADR 0002 and its
  ~$70/month saving to change a file extension.
- **Row-oriented suits append-only raw.** The lake is written constantly and
  read rarely, in whole-partition scans during replay. Columnar formats pay off
  on selective column reads over large scans, which is the warehouse's job, not
  the lake's.
- **Avro carries its schema in the file.** A lake file is self-describing years
  later, without a registry that must still exist to interpret it.

## What we give up

- **Query performance directly against the lake.** Scanning `raw_external` is
  slower than scanning a native BigQuery table. That is correct: the lake is for
  replay and audit, not for interactive querying, and the fast path already
  exists.
- **Compression ratio.** Parquet would be meaningfully smaller. At ~$1/month of
  storage, that saving is not worth a compute step.
