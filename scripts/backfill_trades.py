"""Backfill trades the live feed missed, from the Coinbase REST API.

The lake cannot help here. It is the system of record for everything we
RECEIVED, and an outage means the trades were never received by anything - so
replaying the lake reproduces the gap perfectly. Recovery has to go back to the
exchange.

What makes that tractable is `trade_id` contiguity: the missing range is known
exactly, not estimated. We have up to N, the feed resumed at M, so trades
N+1..M-1 are missing and nothing else is.

Backfilled trades are published to the SAME Pub/Sub topic as live ones, so they
travel the same path: schema validation, both sinks, dedupe in staging. There
is no second code path that could behave differently, and re-running is safe
because staging dedupes on trade_id.

    python scripts/backfill_trades.py --product BTC-USD --after 1086348883 --before 1086349000
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from datetime import UTC, datetime
from typing import Any

API = "https://api.exchange.coinbase.com"
PAGE_SIZE = 1000


def fetch_page(product: str, before_id: int | None) -> list[dict[str, Any]]:
    """One page of trades, newest first.

    Coinbase paginates trades by id descending. `after` in their API means
    "ids lower than this", which is the opposite of what the word suggests -
    hence the deliberate naming below.
    """
    url = f"{API}/products/{product}/trades?limit={PAGE_SIZE}"
    if before_id is not None:
        url += f"&after={before_id}"

    request = urllib.request.Request(url, headers={"User-Agent": "crypto-market-platform/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return list(json.load(response))


def to_topic_payload(trade: dict[str, Any], product: str) -> dict[str, Any]:
    """Match schemas/trades.avsc EXACTLY.

    The topic rejects anything else, which is the point: a backfill cannot
    quietly write a differently-shaped row than the live path.
    """
    now = datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    event_time = trade["time"].replace("+00:00", "Z")
    if not event_time.endswith("Z"):
        event_time += "Z"

    return {
        # The REST endpoint does not expose the feed's `sequence`, and nothing
        # downstream uses it for continuity (ADR 0007). Zero is honest: it
        # marks the row as backfilled rather than inventing a plausible value.
        "sequence": 0,
        "product_id": product,
        "trade_id": int(trade["trade_id"]),
        "price": str(trade["price"]),
        "size": str(trade["size"]),
        "side": str(trade["side"]),
        "maker_order_id": "",
        "taker_order_id": "",
        "event_time": event_time,
        "ingest_time": now,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", required=True)
    parser.add_argument("--after", type=int, required=True, help="last trade_id we already hold")
    parser.add_argument("--before", type=int, required=True, help="first trade_id after the gap")
    parser.add_argument("--project", default="dataengproj01")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    wanted = set(range(args.after + 1, args.before))
    if not wanted:
        print("nothing to backfill: the range is empty")
        return 0

    print(f"backfilling {len(wanted)} trades for {args.product}: {args.after+1}..{args.before-1}")

    collected: dict[int, dict[str, Any]] = {}
    cursor = args.before + PAGE_SIZE

    while wanted - set(collected):
        page = fetch_page(args.product, cursor)
        if not page:
            break

        ids = [int(t["trade_id"]) for t in page]
        for trade in page:
            tid = int(trade["trade_id"])
            if tid in wanted:
                collected[tid] = trade

        # Walk backwards through history until the page is entirely below the
        # range we need.
        cursor = min(ids)
        if cursor <= args.after:
            break

        print(f"  fetched to {cursor}, have {len(collected)}/{len(wanted)}")
        time.sleep(0.2)  # Coinbase public rate limit is 10 req/s; stay well under

    missing = wanted - set(collected)
    if missing:
        print(f"WARNING: {len(missing)} trades not returned by the API", file=sys.stderr)

    if args.dry_run:
        print(f"dry run: would publish {len(collected)} trades")
        return 0

    from google.cloud import pubsub_v1  # type: ignore[attr-defined]

    client = pubsub_v1.PublisherClient(
        publisher_options=pubsub_v1.types.PublisherOptions(enable_message_ordering=True)
    )
    topic = client.topic_path(args.project, "market.raw.trades")

    # Ascending, so the ordering key sees them in the same order the exchange
    # produced them.
    futures = []
    for tid in sorted(collected):
        payload = to_topic_payload(collected[tid], args.product)
        data = json.dumps(payload, separators=(",", ":")).encode()
        futures.append(client.publish(topic, data, ordering_key=args.product))

    for future in futures:
        future.result(timeout=60)

    print(f"published {len(futures)} backfilled trades to market.raw.trades")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
