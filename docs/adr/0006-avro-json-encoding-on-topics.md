# ADR 0006: JSON encoding on Avro-schema'd topics

**Status:** accepted · **Date:** 2026-08-30

## Context

Pub/Sub topic schemas can be Avro or Protobuf, and messages can be encoded as
JSON or binary.

## Decision

Avro schema, **JSON** encoding.

## Rationale

- The native BigQuery subscription supports both, so encoding is a free choice
  there.
- JSON messages are debuggable: `gcloud pubsub subscriptions pull` shows you a
  readable message, and `make smoke` can publish one with a shell heredoc.
  Binary Avro forces a tool between you and the data during exactly the
  incidents where you least want one.
- The volume is 5–8 GB/month against a 10 GB free tier. Binary encoding would
  save perhaps 40% of a number that is already zero dollars.

## The consequence we discovered on first apply

Pub/Sub refuses `use_topic_schema` on a Cloud Storage subscription with Avro
output unless the topic encoding is BINARY. Keeping JSON therefore means the
lake stores the **envelope** - `message_id`, `publish_time`, `attributes`, and
the message body as raw bytes - rather than typed columns.

On reflection this is the better outcome, not a compromise. The lake now holds
exactly what the broker received, byte for byte, and cannot be invalidated by a
later schema change: if a `.avsc` turns out to be wrong about a type, the lake
is still correct and you re-parse. With typed columns, a schema mistake is
baked into the stored files permanently.

Note the deliberate asymmetry: the BigQuery sink DOES use the topic schema.
BigQuery `raw` is a typed convenience cache optimised for querying; the lake is
optimised for fidelity. Different jobs, different tradeoffs.

Revisit if volume approaches the free-tier ceiling; the change is one line in
`schema_settings.encoding` plus a consumer serializer swap - and it would flip
the lake to typed columns as a side effect.
