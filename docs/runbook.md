# Runbook

Written as if handing on-call to someone who has never seen this repo.
Imperative steps only. If a step needs judgement, the judgement is written down.

Phase 1 covers the infrastructure spine. Sections marked *(Phase N)* are
placeholders until that phase lands — they are listed now so the gaps are
visible rather than forgotten.

---

## Terraform state is locked

Symptom: `Error acquiring the state lock`.

1. Confirm no CI run is applying: check the Actions tab for a running `deploy`
   job. The `concurrency` group prevents two applies, but a cancelled runner
   can leave a lock behind.
2. Read the lock info in the error — it names the operation, who, and when.
3. If and only if the holder is a dead run:
   ```bash
   cd infra/envs/dev && terraform force-unlock <LOCK_ID>
   ```
4. Never force-unlock a lock younger than 10 minutes. You will corrupt state.

## The native GCS or BigQuery sink is delivering nothing

This is almost always IAM on the Pub/Sub **service agent**, not on your own
account. Check in this order:

1. Is anything being published at all?
   ```bash
   gcloud pubsub topics list-subscriptions market.raw.trades
   gcloud monitoring ... # or: check the topic's publish rate in Cloud Console
   ```
   No publishes → the problem is upstream, go to *Feed is silent* (Phase 2).
2. Is the subscription backed up?
   ```bash
   gcloud pubsub subscriptions describe market.raw.trades.bq
   ```
   A growing `num_undelivered_messages` with zero deliveries means the sink is
   failing, not idle.
3. Check the service agent's grants. It is
   `service-661305133555@gcp-sa-pubsub.iam.gserviceaccount.com` and it needs
   `roles/storage.objectCreator` on the raw bucket (GCS sink) and
   `roles/bigquery.dataEditor` (BQ sink). These are in
   `infra/modules/pubsub/main.tf`; if they are missing, state has drifted —
   `make plan ENV=dev` will show it.
4. For the BQ sink specifically: a schema mismatch between the topic's Avro
   schema and the table halts delivery with no error visible on the topic.
   Compare `schemas/trades.avsc` against
   `infra/modules/bigquery/raw_tables.tf`. They are meant to be reviewed as a
   pair.
5. Drain check: messages that failed 10 delivery attempts are on
   `market.dlq.trades`. See *Draining a dead-letter queue* below.

## Draining a dead-letter queue

DLQ messages are retained for 7 days on `market.dlq.<channel>.hold`. Nothing
consumes them automatically, on purpose: an automatic drain would hide the
failure that put them there.

1. Look before you drain:
   ```bash
   gcloud pubsub subscriptions pull market.dlq.trades.hold --limit=10 --format=json
   ```
2. Diagnose the common cause. Almost always a schema violation — the message
   shape changed and the topic rejected it, or the BQ table drifted.
3. Fix the cause first. Draining into a still-broken sink just refills the DLQ.
4. Once fixed, replay:
   ```bash
   gcloud pubsub subscriptions pull market.dlq.trades.hold --limit=1000 --auto-ack --format=json \
     > /tmp/dlq.json
   # inspect, then republish the message bodies to market.raw.trades
   ```
5. Record the count and the window in the incident notes — these become rows in
   `fct_data_quality` (Phase 5).

## Costs doubled overnight

1. Billing → Reports, group by SKU, last 7 days. One SKU will dominate.
2. The realistic culprits, in order of likelihood:
   - **Dataflow left running.** It is ~$3/hour and is supposed to run in bursts.
     `gcloud dataflow jobs list --status=active --region=us-central1`, then drain it.
   - **BigQuery query volume.** A dbt full-refresh over the external tables
     scans the whole lake. Check `INFORMATION_SCHEMA.JOBS_BY_PROJECT` for the
     largest `total_bytes_billed` in the window.
   - **GCS class B operations.** The native sink flushing too often creates many
     small objects. Raise `gcs_flush_duration`.
3. Budget alerts fire at 50/80/100% plus a forecast alert. If you learned about
   this from the billing page rather than an alert, the alert config is the
   second bug to fix.

## Rebuild everything from zero

The property the whole design exists to guarantee. It must work; run it
quarterly, not just once.

```bash
make down ENV=dev            # terraform destroy, all of it
make up   ENV=dev            # rebuild
make smoke                   # prove the spine carries data
# Phase 3+: dagster job execute -j backfill_from_lake --config from=... to=...
```

The raw bucket has a retention policy, so `terraform destroy` will refuse to
delete raw objects inside the retention window (7d dev / 90d prod). That is
working as designed — the lake survives the stack. To destroy for real in dev,
wait out the window or empty the bucket deliberately.

## A query returns nothing but the data is definitely there

Before assuming the pipeline is broken, rule this out. Rows arriving through
BigQuery's streaming path sit in an unpartitioned buffer with
`_PARTITIONTIME = NULL` until BigQuery commits them to a date partition, which
can take minutes. So this query:

```sql
WHERE _PARTITIONTIME >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY)
```

excludes precisely the rows that just arrived. Always include the buffer:

```sql
WHERE (_PARTITIONTIME IS NULL
       OR _PARTITIONTIME >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY))
```

The partition filter is still required (`require_partition_filter = true` is a
deliberate cost guard), so you cannot simply drop it.

## Querying raw_external.*_lake fails with "matched no files"

Expected on a fresh stack, and not a fault. An external table over an empty GCS
prefix cannot be scanned - BigQuery errors rather than returning zero rows.

The table is created successfully (its schema is declared, not inferred), so
this only appears at QUERY time, and only until the first file lands. The GCS
sink flushes on `max_duration` (300s in dev), so a newly built environment is
expected to fail this query for the first five minutes of its life.

If it persists beyond that, the sink is genuinely broken - go to *The native GCS
or BigQuery sink is delivering nothing*.

## Terraform fails with SERVICE_DISABLED for a service you never touched

Symptom, typically on `google_billing_budget`:

> Your application is authenticating by using local Application Default
> Credentials... `"consumer": "projects/764086051850"`

That project number is not yours - it is Google's default client project for
`gcloud`. A *human's* credentials carry no quota project, so Google bills the
request against its own project, where the API is naturally disabled.

This affects laptops only. CI authenticates as a service account through
Workload Identity Federation, which has an unambiguous billing project, so the
error never appears there. The fix is already in the provider config
(`billing_project` + `user_project_override`); if you see it again, check ADC:

```bash
gcloud auth application-default set-quota-project dataengproj01
```

## A first apply into a fresh project fails on Pub/Sub IAM

> Error 400: Service account service-<n>@gcp-sa-pubsub... does not exist

GCP creates service agents LAZILY - enabling the API is not enough. The grant
fails, Google provisions the agent moments later, and the retry succeeds, which
makes it look like a flaky cloud rather than a missing dependency edge. The
`google_project_service_identity.pubsub` resource in `modules/pubsub` forces the
agent into existence so this is deterministic. If you see this error, that
resource has been removed or reordered.

---

## The feed is silent

Symptom: `messages_received` flat at zero, or the "Feed silent" alert firing.

1. **Is the consumer alive?**
   ```bash
   gcloud compute instances describe market-ingest-dev --zone us-central1-a \
     --format="value(status)"
   gcloud logging read 'resource.type=gce_instance AND jsonPayload.logger:"consumer"' \
     --limit 20 --format="value(jsonPayload.message,jsonPayload.error)"
   ```
2. **Is it reconnecting in a loop?** Look for repeated `connection lost`. The
   `error_type` field names the cause. Two seen in practice:
   - `ConnectionClosedError ... 1009 (message too big)` - a level2 snapshot
     exceeded the client's frame limit. `WS_MAX_MESSAGE_BYTES` is 64 MB by
     default; a full book snapshot is several MB. If this appears, the book
     grew past the cap.
   - Anything else - treat as an ordinary network drop; backoff handles it.
3. **Is Coinbase itself down?** <https://status.coinbase.com>. If so there is
   nothing to fix; confirm the gap will be visible in `fct_data_quality` and
   wait.
4. **Is it connected but stalled?** A TCP connection can stay open while data
   stops. The heartbeat watchdog forces a reconnect after
   `HEARTBEAT_TIMEOUT_S` (10s). If you see `feed stalled` the detector is
   working; if you see silence with no reconnects, the watchdog is not running
   and that is the bug.
5. **Publishes failing?** `publish_errors_total > 0` with `publish failed` in
   the logs. Read the error: `INVALID_JSON_AVRO_MESSAGE` means the payload no
   longer matches the topic schema - see the next section.

## Every publish for a product suddenly fails

Symptom: one `publish failed` with a real cause, then a flood of
`Batch cancelled because prior ordered message for the same key has failed`.

This is ordering working as designed. With an ordering key, Pub/Sub will not
publish message N+1 after N failed, because doing so would deliver them out of
order. **One bad message stops that product's entire stream.**

1. Find the FIRST error - the rest are consequences, not causes.
2. If it is `INVALID_JSON_AVRO_MESSAGE`, the payload no longer matches the
   topic schema. The mismatch is named in `revisionInfo`. Common cause: a field
   that is a nullable union in the `.avsc`. Avro JSON encodes a union as
   `{"string": "value"}`, NOT a bare value - so a bare string is rejected.
   Prefer a plain type with a default over a union.
3. The publisher calls `resume_publish()` on the key after logging, so recovery
   is automatic once the cause is fixed and the process restarts.

## *(Phase 3)* dbt failed on fct_bars_1m
## *(Phase 3)* dbt failed on fct_bars_1m — diagnose and rerun one partition
## *(Phase 3)* Rebuild the last 7 days from the lake
## Trade gaps spiked — is the data usable?

1. **Which detector fired?** They mean different things:
   - `sequence_gaps_total` - a break in `trade_id` on the match stream.
   - `heartbeat_detected_gaps_total` - the exchange says the latest trade is
     ahead of anything we received. Trades never arrived at all.
   Both are real loss. Neither is measured from the `sequence` field, which is
   not contiguous on our channels - see [ADR 0007](adr/0007-trade-id-not-sequence-for-gap-detection.md).
2. **How bad?** `messages_lost_total` counts trades, not messages, so it is
   directly comparable to volume. The SLA is < 0.01%/hour.
3. **Confirm in SQL** rather than trusting the counter:
   ```sql
   SELECT product_id, COUNT(*) = MAX(trade_id) - MIN(trade_id) + 1 AS contiguous
   FROM `dataengproj01.raw.trades_stream`
   WHERE _PARTITIONTIME >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY)
   GROUP BY product_id
   ```
4. **Backfill.** `trade_id` is contiguous, so the missing range is exactly
   known. The Coinbase REST trades endpoint is paginated by trade id and can
   fill it precisely — *(Phase 3: the `backfill_from_lake` asset)*.
