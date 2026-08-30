# ADR 0001: Pub/Sub over Kafka

**Status:** accepted · **Date:** 2026-08-30

## Context

The ingest path needs a durable buffer between a single WebSocket consumer and
several downstream sinks. Candidates: self-managed Kafka on GCE, Confluent
Cloud, or Cloud Pub/Sub.

## Decision

Cloud Pub/Sub.

## Rationale

- **Volume.** Three products of Coinbase trades and L2 batches is roughly
  5–8 GB/month. Pub/Sub's free tier is 10 GB. Kafka's minimum viable footprint
  is a three-broker cluster, which is ~$150/mo on GCE or ~$100/mo on Confluent
  for a workload that fits in a free tier.
- **Operational surface.** A Kafka cluster is a thing that pages you. It has
  brokers to patch, partitions to rebalance, disks to watch. Nothing about this
  workload justifies owning that.
- **Native sinks.** This is the decisive point. Pub/Sub writes directly to GCS
  and BigQuery with no consumer process at all (see ADR 0002). Kafka would need
  Kafka Connect — another cluster — to do the same thing.
- **Ordering.** Pub/Sub ordering keys give per-`product_id` ordering, which is
  exactly the guarantee the sequence-gap logic needs. Kafka's partition
  ordering would give the same thing, at far higher cost.

## What we give up

- **Replay from the broker.** Kafka retains for as long as you have disk;
  Pub/Sub caps at 7 days. Mitigated structurally: the GCS lake, not the broker,
  is the replay source. Losing 7-day broker replay costs nothing because we
  never intended to replay from the broker.
- **Throughput headroom.** Pub/Sub is more expensive per GB at very high
  volume. At 100× this volume the calculus flips. It won't.
- **Exactly-once semantics.** Pub/Sub is at-least-once, so duplicates are
  handled downstream by deduping on `trade_id`. This is required anyway,
  because the *exchange* replays trades on reconnect.
