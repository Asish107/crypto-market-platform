#!/usr/bin/env bash
# Publishes as TEST-USD, never a real product. A synthetic row wearing a real
# product id lands in fct_trades looking exactly like market data, and breaks
# trade-id contiguity - which is the measurement the whole platform rests on.
#
# Proves the pipeline actually carries data end to end:
#   publish -> topic (schema validated) -> native GCS sink -> native BQ sink
#
# If this passes, the pipeline's spine is real and Phase 2 is only about the
# quality of the messages, not about whether they arrive.
set -euo pipefail

PROJECT_ID="${1:-dataengproj01}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
SEQ="$(date +%s)"

MSG=$(cat <<JSON
{"sequence":${SEQ},"product_id":"TEST-USD","trade_id":${SEQ},"price":"64000.00","size":"0.001","side":"buy","maker_order_id":null,"taker_order_id":null,"event_time":"${NOW}","ingest_time":"${NOW}"}
JSON
)

echo "==> publishing to market.raw.trades (schema validation happens here)"
gcloud pubsub topics publish market.raw.trades \
  --project="${PROJECT_ID}" \
  --message="${MSG}" \
  --ordering-key="TEST-USD"

echo "==> BigQuery sink is near-instant; querying raw.trades_stream"
bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false --format=prettyjson \
  "SELECT sequence, product_id, price, publish_time
     FROM \`${PROJECT_ID}.raw.trades_stream\`
    -- Freshly streamed rows sit in an unpartitioned buffer with a NULL
    -- _PARTITIONTIME until BigQuery commits them to a date partition. A filter
    -- of '_PARTITIONTIME >= today' therefore excludes precisely the rows you
    -- just wrote, and the pipeline looks broken when it is working perfectly.
    WHERE (_PARTITIONTIME IS NULL
           OR _PARTITIONTIME >= TIMESTAMP_TRUNC(CURRENT_TIMESTAMP(), DAY))
      AND sequence = ${SEQ}"

echo "==> GCS sink flushes on max_duration (300s in dev); check with:"
echo "    gsutil ls -r gs://${PROJECT_ID}-market-raw/trades/"
