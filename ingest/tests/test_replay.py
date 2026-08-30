"""Replay a recorded session with injected faults through the consumer.

This is the test the spec singles out, and it is the one that would catch a
regression in the parts that matter: gap detection, duplicate handling, book
reconstruction, and reconnect recovery.

It drives `MessageHandler` directly rather than a socket. The handler is pure
logic over decoded messages, so the faults can be injected exactly and the
whole suite runs in milliseconds - no fake server, no sleeping, no flakes.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

import pytest
from consumer.config import Config
from consumer.metrics import MetricsReporter
from consumer.publisher import RecordingPublisher
from consumer.ws_client import MessageHandler

FIXTURE = Path(__file__).parent / "fixtures" / "session_with_faults.jsonl"
DISCONNECT = "__disconnect__"


def load_session() -> list[dict[str, Any]]:
    with FIXTURE.open() as f:
        return [json.loads(line) for line in f if line.strip()]


@pytest.fixture
def replayed() -> tuple[MessageHandler, RecordingPublisher]:
    """Feed the whole recorded session through a handler and return the result."""
    config = Config(project_id="", products=["BTC-USD"], publish_enabled=False)
    publisher = RecordingPublisher()
    handler = MessageHandler(config, publisher, MetricsReporter("", enabled=False))

    clock = datetime(2026, 8, 30, 12, 0, 0, tzinfo=UTC)
    for message in load_session():
        if message["type"] == DISCONNECT:
            handler.on_disconnect()
            continue
        handler.handle(message, received_at=clock)

    return handler, publisher


# -- the injected faults --------------------------------------------------


def test_trade_gap_is_detected_and_lost_trades_counted(replayed) -> None:
    handler, _ = replayed
    counters = handler.metrics.counters
    assert counters.sequence_gaps_total == 1
    # trades 504, 505, 506 from the match stream, plus 508, 509, 510 that the
    # heartbeat revealed were never delivered at all
    assert counters.messages_lost_total == 6


def test_replayed_message_counted_as_duplicate_not_as_a_gap(replayed) -> None:
    handler, _ = replayed
    assert handler.metrics.counters.duplicates_total == 1


def test_duplicate_is_still_published_for_downstream_dedupe(replayed) -> None:
    """The consumer does not drop duplicates. Deduping needs the full picture
    and belongs in dbt, where it is idempotent and testable; silently dropping
    here would hide a reconnect storm from fct_data_quality."""
    _, publisher = replayed
    trade_ids = [t["trade_id"] for t in publisher.for_channel("trades")]
    assert trade_ids.count(507) == 2


def test_size_zero_removed_the_level_rather_than_zeroing_it(replayed) -> None:
    handler, _ = replayed
    # 100.25 was added then removed; best bid must be back to the snapshot's
    # 100.00, not stuck at a level holding zero.
    book = handler.books["BTC-USD"]
    assert book.ready
    # after reconnect the book is the post-snapshot one
    assert book.best_bid() == (Decimal("200.00"), Decimal("1.0"))


def test_update_before_the_post_reconnect_snapshot_is_dropped(replayed) -> None:
    """The subtlest correctness case in the whole consumer. A delta arriving
    between the drop and the fresh snapshot must not be applied - the 999.00
    bid must not exist anywhere in the final book."""
    handler, _ = replayed
    book = handler.books["BTC-USD"]
    best_bid = book.best_bid()
    assert best_bid is not None
    assert best_bid[0] == Decimal("200.00")
    assert best_bid[0] != Decimal("999.00")


def test_heartbeat_reveals_trades_that_never_arrived_as_messages(replayed) -> None:
    """The gap you cannot otherwise see. Trades 508-510 were never delivered
    as `match` messages at all, so the match stream has no discontinuity to
    notice - you cannot observe the absence of a message you never received.
    The heartbeat's last_trade_id is the only witness."""
    handler, _ = replayed
    assert handler.metrics.counters.heartbeat_detected_gaps_total == 1


def test_no_phantom_gap_after_reconnect(replayed) -> None:
    """trade_id jumps from 510 to 900 across the reconnect. Without the reset
    that reads as 389 lost trades."""
    handler, _ = replayed
    assert handler.metrics.counters.sequence_gaps_total == 1  # the real one only
    assert handler.metrics.counters.messages_lost_total == 6


def test_book_is_usable_again_after_the_reconnect_snapshot(replayed) -> None:
    handler, _ = replayed
    quote = handler.books["BTC-USD"].quote()
    assert quote is not None
    assert quote.bid_price == Decimal("200.00")
    assert quote.ask_price == Decimal("201.00")


# -- publishing contract --------------------------------------------------


def test_every_channel_publishes_to_its_own_topic(replayed) -> None:
    _, publisher = replayed
    channels = {c for c, _, _ in publisher.messages}
    assert channels == {"trades", "l2", "heartbeat"}


def test_ordering_key_is_always_the_product(replayed) -> None:
    """Pub/Sub only guarantees order per key, and the sequence logic
    downstream assumes per-product order."""
    _, publisher = replayed
    assert {k for _, _, k in publisher.messages} == {"BTC-USD"}


def test_published_trades_match_the_avro_contract(replayed) -> None:
    """The topic schema rejects a mismatch at the broker, so a shape error
    here is total message loss for that channel. Worth asserting locally."""
    _, publisher = replayed
    required = {
        "sequence",
        "product_id",
        "trade_id",
        "price",
        "size",
        "side",
        "maker_order_id",
        "taker_order_id",
        "event_time",
        "ingest_time",
    }
    trades = publisher.for_channel("trades")
    assert trades
    for trade in trades:
        assert set(trade) == required
        assert isinstance(trade["sequence"], int)
        assert isinstance(trade["trade_id"], int)
        assert isinstance(trade["price"], str)  # strings at the raw layer


def test_ingest_lag_is_recorded_from_exchange_time(replayed) -> None:
    """Lag measured from ingest time would report a stalled feed as perfectly
    fresh. It has to come from the exchange's own timestamp."""
    handler, _ = replayed
    assert handler.metrics.counters.ingest_lag_samples_ms


def test_unknown_message_types_do_not_crash_the_consumer(replayed) -> None:
    """Coinbase adds message types without notice; an unhandled one must not
    take the feed down."""
    handler, _ = replayed
    handler.handle({"type": "some_future_type", "product_id": "BTC-USD"})
