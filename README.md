# crypto-market-platform

A real-time crypto market data lakehouse on GCP. It captures every trade and
every order-book change on three Coinbase pairs, lands them immutably, and
serves quant-grade microstructure marts with tested SLAs.

**The defining property:** you can `terraform destroy` the entire stack, rebuild
it, replay history from the lake, and get identical marts.

| | |
|---|---|
| **Project** | `dataengproj01` (number `661305133555`) |
| **Region** | `us-central1` |
| **Live resources** | 69, all Terraform-managed, zero console clicks |
| **Status** | Phases 1-4 complete; marts built from live market data |
| **Cost today** | ~$0/mo (no compute running; ~$34/mo at full build) |

---

## 1. What problem this solves

Coinbase's public WebSocket feed is deliberately hard to consume correctly, and
that difficulty is the point of the project:

| Problem | Why it's dangerous | Where it's handled |
|---|---|---|
| The feed **drops and reorders** messages | Nothing errors. You just silently lose trades and your volume is wrong forever. | `sequence` on every message; gap detection in the consumer (Phase 2) |
| The order book is a **state machine** | You get one snapshot, then deltas. Miss one and every spread you compute afterwards is wrong. | `book.py` state machine (Phase 2) |
| A dead connection **looks like a quiet market** | TCP holds the socket open while data stops. | `heartbeat` channel + 10s watchdog (Phase 2) |
| Reconnects **replay** data | The same trade arrives twice. | Idempotent dedupe on `trade_id` (Phase 3) |

The output is a small set of tables a quant could actually use — plus one that
measures whether the others can be trusted:

| Question | Table | Status |
|---|---|---|
| OHLC, volume, VWAP per minute? | `marts.fct_bars_1m` | ✅ |
| Same, coarser | `fct_bars_5m`, `fct_bars_1h` | ✅ |
| How expensive was it to trade? How deep was the book? | `marts.fct_liquidity_1m` | ✅ |
| How volatile, by several estimators? | `marts.fct_realized_vol` | ✅ |
| **Can I trust any of the above?** | `marts.fct_data_quality` | Phase 5 |

Real output, from live Coinbase data:

```
product  minute  best_bid   best_ask   spread_bps  depth_25bps_usd  imbalance
BTC-USD  00:12   77630.84   77630.85       0.001       $5,635,479      -0.131
ETH-USD  21:46    2475.81    2475.82       0.040       $2,323,409       0.071
SOL-USD  21:46     104.22     104.25       2.878       $1,251,948       0.181
```

The spreads rank the way the market does - BTC tightest, SOL widest - which is
the strongest signal the book reconstruction is correct.

That last row is what separates this from a tutorial pipeline. Most pipelines
produce numbers. This one produces numbers *and a measurement of its own
trustworthiness*.

---

## 2. Architecture

```
Coinbase WS (ws-feed.exchange.coinbase.com)
        │  matches · level2_batch · heartbeat
        ▼
┌────────────────────────────┐
│ Ingest consumer (Phase 2)  │  GCE e2-small, always-on
│ reconnect · seq gaps ·     │  publishes with ordering_key = product_id
│ book state · SIGTERM drain │
└─────────────┬──────────────┘
              ▼
    ┌──────────────────────┐
    │ Pub/Sub  (3 topics)  │  Avro schemas enforced AT THE BROKER
    │ + 3 dead-letter topics│
    └───┬──────────────┬───┘
        │              │        ← both are NATIVE subscriptions:
        ▼              ▼           zero compute, zero servers
   GCS Avro lake   BigQuery raw
   (system of      (typed cache,
    record)         expires 14d)
        │              │
        │              ▼
        │        dbt: staging → intermediate → marts   (Phase 3-4)
        │
        └──► external tables ──► REPLAY PATH: rebuild any mart from the lake
```

### The load-bearing idea

**Raw data is immutable and append-only. Every other table is a pure function
of it.**

Found a bug in your VWAP formula? Fix the SQL, rerun, done — you never re-fetch
anything, because the truth is still in the lake. Contrast with a system that
transforms on write, where a bug is permanent data loss. This is what makes
destroy-and-rebuild possible at all.

### Two sinks, two different jobs

|  | GCS lake | BigQuery `raw` |
|---|---|---|
| **Role** | System of record | Convenience cache |
| **Contents** | Pub/Sub envelope + message body as **raw bytes** | **Typed** columns |
| **Retention** | 7d lock (dev) / 90d (prod), versioned | 14d expiry |
| **If you lost it** | Catastrophe | Shrug, rebuild from the lake |

The asymmetry is deliberate: the cache optimises for querying, the lake
optimises for fidelity. The lake holds exactly what the broker received, byte
for byte, so a wrong `.avsc` can be re-parsed rather than being baked into
storage permanently. See [ADR 0006](docs/adr/0006-avro-json-encoding-on-topics.md).

### No Dataflow in the hot path

Pub/Sub's native GCS and BigQuery subscriptions land raw data with **zero
streaming compute**. A Dataflow job doing the same work costs ~$70/mo and adds
a job graph, a worker pool, and drain semantics to your on-call surface — to
serialize bytes. Dataflow appears only in Phase 6, for windowed aggregation,
where it earns its keep. See [ADR 0002](docs/adr/0002-native-sinks-over-dataflow.md).

---

## 3. The code, file by file

### `schemas/` — the contract

Three Avro schemas, registered **on the Pub/Sub topics themselves**. This is the
first line of defence: a malformed message is rejected by the broker, not
discovered three layers downstream by a dbt test at 2am.

| File | Channel | Notes |
|---|---|---|
| `trades.avsc` | `matches` | The tick tape. `trade_id` is the dedupe key. |
| `l2.avsc` | `level2_batch` | Deltas carried as a JSON string, so the raw layer needs no migration when Coinbase adds a field. |
| `heartbeat.avsc` | `heartbeat` | Liveness + sequence continuity. |

All numerics stay **strings** and times stay **RFC3339 strings** at this layer.
Casting is staging's job — raw preserves what arrived.

### `infra/bootstrap/` — the chicken-and-egg problem

Run **once**, from a laptop, with **local state**. It creates the two things
that cannot be created by the thing that needs them:

- `gs://dataengproj01-tfstate` — the versioned remote state bucket
- The Workload Identity Federation pool + provider

`attribute_condition = "assertion.repository == 'Asish107/crypto-market-platform'"`
is the single most important line in the file. Without it, **any** GitHub repo
on earth could mint tokens for your project.

> Bootstrap is a **two-pass** apply. The second pass takes
> `-var deployer_sa_email=...` to attach the WIF binding, once `envs/dev` has
> created that service account. Skipping pass two leaves CI able to
> authenticate and authorised to do nothing — see §6.

### `infra/modules/` — one concern per module

| Module | Resources | What to notice |
|---|---|---|
| **`storage`** | 3 | The raw bucket has a GCS **retention policy**, not an IAM promise. An operator with `storage.admin` still cannot delete an object inside the window. Lifecycle: Standard → Nearline 30d → Coldline 90d. |
| **`pubsub`** | 27 | Topics, registered schemas, both native sinks, DLQs. Read `main.tf` for the filename-grammar and encoding constraints — they shaped the lake layout. |
| **`bigquery`** | 20 | 7 datasets, raw tables whose DDL sits **beside** the `.avsc` so they're reviewed as a pair, and external tables over the lake. |
| **`iam`** | 16 | Three least-privilege SAs. There is no `roles/editor` in this repo and adding one should fail review. |
| **`budget`** | 3 | $25 dev cap, alerts at 50/80/100% of actual **plus forecast** — the forecast one catches a Dataflow job left running on a Friday. |

**Grants are scoped where they belong.** The ingest SA holds only
`logging.logWriter` + `monitoring.metricWriter` at project level; its publish
right is granted on **exactly the three topics**, in the module that owns them.
Verified in §6.

### `infra/envs/{dev,prod}` — compositions

Wire the modules together. They differ **only** in retention, table expiry, and
budget, so the dev→prod diff stays reviewable:

| | dev | prod |
|---|---|---|
| Raw lake retention | 7 days | 90 days |
| BigQuery raw expiry | 14 days | 90 days |
| Budget | $25 | $75 |

`module.pubsub` carries `depends_on = [module.bigquery]` — a BigQuery
subscription created before its destination table exists is born permanently
unhealthy. That's an ordering bug invisible in a plan and obvious at 3am.

### `.github/workflows/`

**`pr.yml`** — ruff, `mypy --strict`, pytest, `terraform fmt/validate/plan` for
both envs, plan posted as a PR comment.
**`deploy.yml`** — `terraform apply` on merge, concurrency-guarded so two
applies can never race the same state.

Auth is **Workload Identity Federation**: GitHub presents an OIDC token, GCP
exchanges it for short-lived credentials. **No service account JSON key exists
anywhere.** Nothing to leak, nothing to rotate.

### `ingest/` — the consumer

| File | Contents |
|---|---|
| `sequence.py` | Continuity detection, keyed on **`trade_id`**. Pure logic. |
| `book.py` | L2 state machine. Snapshot + deltas, crossed-book invariant, depth. |
| `ws_client.py` | `MessageHandler` (pure routing) + `WebSocketConsumer` (socket, backoff, watchdog). |
| `publisher.py` | Pub/Sub with `ordering_key = product_id`, fire-and-forget + error callback. |
| `metrics.py` | In-process counters flushed to Cloud Monitoring on an interval. |
| `logs.py` | JSON formatter that actually emits `extra` fields. |
| `tests/` | 37 tests, **0.03s**. Includes the recorded-session replay with injected faults. |

The split that matters: **`MessageHandler` never touches the network.** Every
interesting behaviour — gaps, duplicates, reconnect recovery, book corruption —
is tested by feeding it a recorded stream, with no fake server and no sleeping.

Run it locally against the live feed without touching GCP:

```bash
PYTHONPATH=ingest/src PUBLISH_ENABLED=false METRICS_ENABLED=false \
  .venv/bin/python -m consumer
```

### `transform/` — dbt

| Layer | Models |
|---|---|
| staging | `stg_trades` (cast, dedupe, lag), `stg_l2_events` (flatten deltas + snapshots), `stg_heartbeats` |
| intermediate | `int_book_state_1m` — the order book rebuilt in SQL from snapshot + deltas |
| marts | `fct_trades`, `fct_bars_1m/5m/1h`, `fct_liquidity_1m`, `fct_realized_vol`, `dim_products` |

**34 tests.** The ones that matter are not generic:

- `assert_trade_ids_contiguous` — data loss, in SQL. Deliberately duplicates the
  consumer's in-memory check, because the consumer can only see what it
  received; it cannot audit what was written.
- `assert_no_crossed_book` — bid < ask, always. Caught **three** separate real
  bugs, none of which looked wrong anywhere else.
- `assert_bar_volume_reconciles` — bars must account for every trade exactly
  once, checked back against the tape.
- `assert_all_products_present` — absence is invisible to tests that only
  inspect the rows that are there.

### `orchestration/` — Dagster

Every dbt model is an asset, so the lineage graph *is* the dbt DAG rather than a
drawing of it that drifts. Hourly schedule, plus a freshness sensor that refuses
to run dbt on a frozen feed — a stale mart is worse than a missing one, because
it looks fine.

### `streaming/`

Skeleton for Phase 6.

### `docs/`

| File | Contents |
|---|---|
| **`runbook.md`** | **The most important file.** Imperative on-call steps. |
| `adr/000{1,2,6}` | Decisions *with what they cost*, not just what was chosen. |
| `slas.md` | Freshness/completeness commitments and how each is enforced. |
| `cost.md`, `architecture.md`, `data-dictionary.md`, `recovery-drill.md` | Phase 7 stubs, honestly marked as such. |

`runbook.md` already answers, in steps: a stale state lock, a native sink
delivering nothing, draining a DLQ, a cost spike, rebuilding from zero, and the
three failure modes we hit for real during Phase 1.

### `Makefile` / `scripts/smoke_test.sh`

`make up ENV=dev`, `make down`, `make check` (everything CI runs, locally),
`make smoke` — publishes one synthetic trade and proves it lands in **both**
sinks.

---

## 4. Quickstart

```bash
# one time: state bucket + WIF (local state)
cd infra/bootstrap
terraform init && terraform apply -var github_repo=Asish107/crypto-market-platform

# the stack
cp infra/envs/dev/terraform.tfvars.example infra/envs/dev/terraform.tfvars
$EDITOR infra/envs/dev/terraform.tfvars     # billing_account, alert_email
make up ENV=dev

# bootstrap pass two — attach the WIF binding (do NOT skip)
cd infra/bootstrap
terraform apply -var github_repo=Asish107/crypto-market-platform \
  -var deployer_sa_email=market-deployer-dev@dataengproj01.iam.gserviceaccount.com

# prove the spine carries data
make smoke
```

Set as GitHub **repository variables** (none are secret): `WIF_PROVIDER`,
`DEPLOYER_SA`, `BILLING_ACCOUNT`, `ALERT_EMAIL`.

---

## 5. Lake layout (and why it looks like this)

```
gs://dataengproj01-market-raw/
  trades/dt=2026-08-30/17_56_25_f3b183.avro
  l2/dt=2026-08-30/18_38_54_9b2c69.avro
  heartbeat/dt=2026-08-30/18_38_56_842a74.avro
  \______/\____________/\_________________/
   prefix   hive level        filename
```

The original design called for `dt=`/`hour=`/`product=`. **That layout is not
achievable through a native Pub/Sub sink**, and finding out why was most of
Phase 1:

- Pub/Sub's filename format requires **all six** datetime matchers
  (`YYYY MM DD hh mm ss`), permits each **exactly once**, and allows **no
  literal text** beyond `-` `_` `:` `/`. So `hour=` cannot appear in it.
- BigQuery hive partitioning requires `key=value` directories.
- The only free text available is the static `filename_prefix`.

⇒ exactly **one** hive level, and it must be the useful one: `dt`.

Hour moved into the filename; product is a **clustering key** instead of a path
segment. Neither costs anything real — every downstream model partitions by
**day**, so hour-level pruning would never have been used, and 24× the
partitions makes BigQuery's metadata layer slower, not faster. The constraint
pushed toward the design that was already correct.

---

## 6. Phase 1 verification — 18/18

Not "the plan is clean" — the actual paths were exercised.

| # | Check | Result |
|---|---|---|
| 1–3 | `fmt` clean · dev has zero drift · prod validates | ✅ |
| 4 | ruff + `mypy --strict` + pytest | ✅ |
| 5 | All three channels accept valid messages | ✅ |
| 6 | **Broker rejects a malformed message** | ✅ `INVALID_JSON_AVRO_MESSAGE` |
| 7 | All three land in BigQuery `raw` | ✅ |
| 8 | Bucket: 7d retention lock, versioning, 3 lifecycle rules | ✅ |
| 9 | Budget $25, 50/80/100% + forecast | ✅ |
| 10 | Ingest SA holds **only** logWriter + metricWriter | ✅ |
| 11 | No `roles/editor` or `roles/owner` on any SA | ✅ |
| 12 | Publish right is **topic-scoped**, not project-wide | ✅ |
| 13 | Dead-letter policy on every sink, 10 attempts | ✅ |
| 14 | WIF scoped to one repo only | ✅ |
| 15 | CI can impersonate the deployer SA | ⚠️ **was broken → fixed** |
| 16 | Lake files for all three channels | ✅ |
| 17 | All three external tables readable | ✅ |
| 18 | **Lake and warehouse agree** | ✅ `1 / 1 / 1` |

Check 18 is the seed of the Phase 6 reconciliation model: both sinks received
the same message independently and produced the same row.

**Check 15 is why verification beat inspection.** WIF pool present, provider
correctly scoped, `terraform plan` clean — and CI still could not have deployed
anything, because nothing was bound to the pool. The binding is `count`-gated on
a variable defaulting to empty, and *a resource counted out is not drift* — it's
absent. The plan said "matches configuration" because it did; the configuration
was incomplete.

> **A clean plan proves your config was applied. It says nothing about whether
> the system works.** Only exercising the real path tells you that — which is
> the whole argument for the recovery drill in Phase 7.

---

## 7. What Phase 1 cost, in lessons

Nine applies, each surfacing a distinct real constraint. All are now encoded in
the repo, so a rebuild from zero hits none of them. The reusable ones are in
[`runbook.md`](docs/runbook.md):

| Symptom | Actual cause |
|---|---|
| `Service account service-…@gcp-sa-pubsub… does not exist` | GCP creates service agents **lazily**; enabling the API isn't enough. Fixed with `google_project_service_identity`. |
| `Role roles/storage.legacyBucketReader is not supported` | It's a **bucket**-level role, granted at project level. The fix made it *more* least-privilege. |
| `SERVICE_DISABLED` on a project number that isn't yours | A human's ADC carries no quota project, so Google billed its own. **Laptop-only** — CI uses a service account and never sees it. |
| `matched no files` creating an external table | Schema **inference** needs files. Declaring the schema breaks the circle — and is better anyway. |
| Query returns nothing, data is there | Streamed rows sit in an unpartitioned buffer with `_PARTITIONTIME = NULL`. |

---

## 8. Build order

| Phase | Deliverable | Status |
|---|---|---|
| **1** | Terraform skeleton, CI, WIF, buckets, Pub/Sub | ✅ **complete, verified 18/18** |
| **2** | Consumer → Pub/Sub → GCS + BQ raw | ✅ **complete, live data landing** |
| **3** | dbt staging, `fct_trades`, tests, Dagster | ✅ **complete, 34 tests in CI** |
| **4** | Bars, liquidity, realised vol marts | ✅ **complete** |
| 5 | Observability, alerts, `fct_data_quality` | next |
| 6 | Dataflow streaming + reconciliation model | |
| 7 | Docs, recovery drill, cost report | |

Phases 1–3 are the hard part. Once raw data lands reliably and CI is strict,
everything after is additive.

---

## 9. Cost

| Item | Now | At full build |
|---|---|---|
| Pub/Sub, GCS, BigQuery | ~$0 (free tiers) | ~$3.50/mo |
| GCE e2-small (ingest) | — | ~$13/mo |
| Cloud Run (Dagster) + Cloud SQL f1-micro | — | ~$17/mo |
| **Total** | **~$0/mo** | **~$34/mo** |
| Dataflow (burst runs only) | — | ~$3/hour while running |

Budget alerts at 50/80/100% of $25 (dev), plus a forecast alert.

---

## Non-negotiables

If scope gets cut, cut marts — never these:

1. Terraform from commit one. No console clicks.
2. Immutable raw lake with a working replay path.
3. Tests that fail CI, not tests that exist.
4. The runbook.
5. The recovery drill.
