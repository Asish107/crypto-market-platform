# Architecture

```mermaid
flowchart TB
    CB["Coinbase WS<br/>matches · level2_batch · heartbeat"]

    subgraph ingest["Ingest — GCE e2-small, always on"]
        WS["ws_client.py<br/>reconnect · heartbeat watchdog"]
        BK["book.py<br/>L2 state machine"]
        SQ["sequence.py<br/>trade_id continuity"]
        PB["publisher.py<br/>ordering_key = product_id"]
    end

    subgraph ps["Pub/Sub — Avro schemas enforced at the broker"]
        T1["market.raw.trades"]
        T2["market.raw.l2"]
        T3["market.raw.heartbeat"]
        DLQ["market.dlq.*"]
    end

    LAKE[("GCS lake<br/>Avro, immutable<br/>SYSTEM OF RECORD")]
    RAW[("BigQuery raw<br/>typed cache, 14d")]

    subgraph dbt["dbt"]
        STG["staging<br/>cast · dedupe · lag"]
        INT["intermediate<br/>book reconstruction"]
        MART["marts<br/>trades · bars · liquidity · vol · quality"]
    end

    DF["Dataflow<br/>1-min windows, 30s lateness<br/>BURST RUNS ONLY"]
    RECON["fct_stream_batch_recon<br/>where the two paths disagree"]

    CB --> WS --> BK & SQ --> PB
    PB --> T1 & T2 & T3
    T1 & T2 & T3 -.failures.-> DLQ
    T1 & T2 & T3 --> LAKE
    T1 & T2 & T3 --> RAW
    LAKE -.->|"replay path"| STG
    RAW --> STG --> INT --> MART
    T1 --> DF --> RECON
    MART --> RECON
```

## Component responsibilities

| Component | Owns | Explicitly does not |
|---|---|---|
| **Consumer** | Connection lifecycle, book state, gap detection, publishing | Any transformation — parsing beyond field extraction belongs in dbt, where it is tested and reproducible |
| **Pub/Sub** | Durable buffer, schema enforcement, fan-out | Ordering across products (only per `ordering_key`) |
| **GCS lake** | The system of record, byte-for-byte | Being queryable quickly — that is the warehouse's job |
| **BigQuery raw** | Fast querying of recent data | Being authoritative; it expires and is rebuildable |
| **dbt** | All transformation logic | Ingestion or scheduling |
| **Dagster** | Scheduling, lineage, freshness sensing | Transformation logic — it invokes dbt, it does not reimplement it |
| **Dataflow** | Streaming aggregation for reconciliation | The ingest path (ADR 0002) |

## The three properties everything else serves

**1. Raw is immutable; everything else is a pure function of it.**
Fix a bug in a formula, re-run, done — no re-fetching, because the truth is
still in the lake. A system that transforms on write turns a bug into permanent
data loss.

**2. Loss is measurable, not assumed.**
`trade_id` is contiguous per product, so completeness is arithmetic rather than
a guess. `fct_data_quality` publishes it hourly and the SLA is tested.

**3. Reruns are idempotent.**
`insert_overwrite` on the date partition means running a model once or ten
times produces the same table. Retries, backfills and overlapping schedules
all happen.
