"""Coinbase WebSocket consumer.

The message handling is separated from the socket on purpose. `MessageHandler`
is pure logic over decoded messages - no network, no sleeping, no clock - so
the interesting behaviour (gaps, duplicates, reconnect recovery) is tested by
feeding it a recorded stream rather than by standing up a fake server.

`WebSocketConsumer` owns everything that touches the network: connecting,
backoff, the heartbeat watchdog, and draining on shutdown.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import random
from datetime import UTC, datetime
from typing import Any

from consumer.book import BookSet, CrossedBookError
from consumer.config import CHANNELS, Config
from consumer.metrics import MetricsReporter
from consumer.publisher import Publisher
from consumer.sequence import Continuity, ContinuityTracker

log = logging.getLogger(__name__)


def parse_time(value: str) -> datetime:
    """Coinbase sends RFC3339 with a trailing Z, which fromisoformat rejects
    before 3.11 and accepts after. Normalising keeps it explicit either way."""
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


class MessageHandler:
    """Decoded message in, published payload out. Pure and synchronous."""

    def __init__(
        self,
        config: Config,
        publisher: Publisher,
        metrics: MetricsReporter,
    ) -> None:
        self.config = config
        self.publisher = publisher
        self.metrics = metrics
        self.continuity = ContinuityTracker()
        self.books = BookSet(config.products)
        self.last_heartbeat_at: datetime | None = None

    def handle(self, message: dict[str, Any], received_at: datetime | None = None) -> None:
        received_at = received_at or datetime.now(UTC)
        msg_type = message.get("type")

        if msg_type == "match" or msg_type == "last_match":
            self._handle_match(message, received_at)
        elif msg_type == "snapshot":
            self._handle_snapshot(message, received_at)
        elif msg_type == "l2update":
            self._handle_l2update(message, received_at)
        elif msg_type == "heartbeat":
            self._handle_heartbeat(message, received_at)
        elif msg_type == "error":
            log.error("feed error", extra={"message": message})
        # subscriptions / unknown types are ignored rather than crashing the
        # consumer - the exchange adds message types without notice.

    # -- per type ---------------------------------------------------------

    def _handle_match(self, msg: dict[str, Any], received_at: datetime) -> None:
        product_id = msg["product_id"]
        self.metrics.counters.record_message("trades")
        # trade_id, NOT sequence - see consumer/sequence.py for why.
        self._track_continuity(product_id, int(msg["trade_id"]))

        event_time = parse_time(msg["time"])
        self.metrics.counters.record_lag((received_at - event_time).total_seconds() * 1000)

        self.publisher.publish(
            "trades",
            {
                "sequence": int(msg["sequence"]),
                "product_id": product_id,
                "trade_id": int(msg["trade_id"]),
                "price": str(msg["price"]),
                "size": str(msg["size"]),
                "side": str(msg["side"]),
                # Empty string, never None: the topic schema declares these as
                # plain strings, and an Avro union would require the JSON to be
                # {"string": "..."} rather than a bare value.
                "maker_order_id": str(msg.get("maker_order_id") or ""),
                "taker_order_id": str(msg.get("taker_order_id") or ""),
                "event_time": _iso(event_time),
                "ingest_time": _iso(received_at),
            },
            ordering_key=product_id,
        )

    def _handle_snapshot(self, msg: dict[str, Any], received_at: datetime) -> None:
        product_id = msg["product_id"]
        self.metrics.counters.record_message("l2")

        bids = [(p, s) for p, s in msg.get("bids", [])]
        asks = [(p, s) for p, s in msg.get("asks", [])]
        self.books[product_id].apply_snapshot(bids, asks)

        self.publisher.publish(
            "l2",
            {
                "sequence": int(msg.get("sequence", 0)),
                "product_id": product_id,
                "event_type": "snapshot",
                "payload": json.dumps({"bids": bids, "asks": asks}, separators=(",", ":")),
                "event_time": _iso(received_at),
                "ingest_time": _iso(received_at),
            },
            ordering_key=product_id,
        )

    def _handle_l2update(self, msg: dict[str, Any], received_at: datetime) -> None:
        product_id = msg["product_id"]
        self.metrics.counters.record_message("l2")

        changes = [(side, price, size) for side, price, size in msg.get("changes", [])]
        self.books[product_id].apply_updates(changes)

        # Check the invariant on every update. A crossed book means our
        # reconstruction is broken, and the sooner that is loud the less
        # poisoned data reaches the marts.
        try:
            self.books[product_id].quote()
        except CrossedBookError as exc:
            self.metrics.counters.crossed_books_total += 1
            log.error("crossed book", extra={"product_id": product_id, "error": str(exc)})

        event_time = parse_time(msg["time"]) if "time" in msg else received_at
        self.publisher.publish(
            "l2",
            {
                "sequence": int(msg.get("sequence", 0)),
                "product_id": product_id,
                "event_type": "l2update",
                "payload": json.dumps({"changes": changes}, separators=(",", ":")),
                "event_time": _iso(event_time),
                "ingest_time": _iso(received_at),
            },
            ordering_key=product_id,
        )

    def _handle_heartbeat(self, msg: dict[str, Any], received_at: datetime) -> None:
        product_id = msg["product_id"]
        self.metrics.counters.record_message("heartbeat")
        self.last_heartbeat_at = received_at

        # Independent cross-check. The heartbeat reports the exchange's latest
        # trade_id, so if it is AHEAD of the last trade we saw, we missed
        # trades that never arrived as `match` messages at all - a gap the
        # match stream alone can never reveal, because you cannot notice the
        # absence of a message you never received.
        #
        # The heartbeat legitimately LAGS the match stream, so only a heartbeat
        # ahead of us is evidence of loss.
        last_trade_id = int(msg.get("last_trade_id", 0))
        seen = self.continuity.last_seen(product_id)
        if seen is not None and last_trade_id > seen:
            missed = last_trade_id - seen
            self.metrics.counters.heartbeat_detected_gaps_total += 1
            self.metrics.counters.messages_lost_total += missed
            log.warning(
                "heartbeat reports trades we never received",
                extra={
                    "product_id": product_id,
                    "last_seen_trade_id": seen,
                    "heartbeat_last_trade_id": last_trade_id,
                    "missed": missed,
                },
            )
            self.continuity.observe(product_id, last_trade_id)

        self.publisher.publish(
            "heartbeat",
            {
                "sequence": int(msg["sequence"]),
                "product_id": product_id,
                "last_trade_id": int(msg.get("last_trade_id", 0)),
                "event_time": _iso(parse_time(msg["time"])),
                "ingest_time": _iso(received_at),
            },
            ordering_key=product_id,
        )

    # -- shared -----------------------------------------------------------

    def _track_continuity(self, product_id: str, trade_id: int) -> None:
        obs = self.continuity.observe(product_id, trade_id)

        if obs.continuity is Continuity.GAP:
            self.metrics.counters.sequence_gaps_total += 1
            self.metrics.counters.messages_lost_total += obs.missing
            log.warning(
                "trade gap",
                extra={
                    "product_id": product_id,
                    "expected_trade_id": trade_id - obs.missing,
                    "received_trade_id": trade_id,
                    "missing": obs.missing,
                },
            )
        elif obs.continuity is Continuity.DUPLICATE:
            self.metrics.counters.duplicates_total += 1

    def on_disconnect(self) -> None:
        """Invalidate all derived state.

        Both resets matter. Without the book reset, deltas arriving before the
        new snapshot corrupt a stale book. Without the continuity reset, the
        resumed stream risks reading as data loss.
        """
        self.books.reset_all()
        self.continuity.reset_all()
        self.last_heartbeat_at = None
        self.metrics.counters.book_resets_total += 1


def _iso(dt: datetime) -> str:
    return dt.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class WebSocketConsumer:
    """Owns the socket: connect, subscribe, watchdog, backoff, drain."""

    def __init__(self, config: Config, handler: MessageHandler) -> None:
        self.config = config
        self.handler = handler
        self._stopping = asyncio.Event()

    def subscribe_message(self) -> dict[str, Any]:
        return {
            "type": "subscribe",
            "product_ids": self.config.products,
            "channels": CHANNELS,
        }

    async def run(self) -> None:
        """Reconnect forever with capped exponential backoff and jitter.

        Jitter matters even for a single consumer: without it, a consumer that
        reconnects on a fixed schedule after an exchange-wide outage arrives in
        lockstep with everyone else's.
        """
        import websockets

        backoff = self.config.backoff_initial_s

        while not self._stopping.is_set():
            try:
                async with websockets.connect(
                    self.config.ws_url,
                    ping_interval=20,
                    max_size=self.config.ws_max_message_bytes,
                ) as ws:
                    await ws.send(json.dumps(self.subscribe_message()))
                    log.info("connected", extra={"products": self.config.products})
                    backoff = self.config.backoff_initial_s  # reset only after success

                    await self._consume(ws)

            except Exception as exc:
                if self._stopping.is_set():
                    break
                log.warning(
                    "connection lost",
                    exc_info=log.isEnabledFor(logging.DEBUG),
                    extra={
                        "error": str(exc),
                        "error_type": type(exc).__name__,
                        "backoff_s": backoff,
                    },
                )

            self.handler.on_disconnect()
            self.handler.metrics.counters.websocket_reconnects_total += 1

            if self._stopping.is_set():
                break

            await asyncio.sleep(backoff * (0.5 + random.random()))
            backoff = min(backoff * 2, self.config.backoff_max_s)

    async def _consume(self, ws: Any) -> None:
        """Read until the socket closes or the watchdog fires."""
        watchdog = asyncio.create_task(self._watchdog())
        try:
            async for raw in ws:
                if self._stopping.is_set():
                    return
                self.handler.handle(json.loads(raw))
        finally:
            watchdog.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await watchdog

    async def _watchdog(self) -> None:
        """Force a reconnect if heartbeats stop.

        This is the silent-stall detector. A TCP connection can stay open
        indefinitely while the exchange sends nothing, and every other signal -
        socket state, ping/pong, message rate - looks identical to a quiet
        market. Only the absence of an expected heartbeat distinguishes them.
        """
        while not self._stopping.is_set():
            await asyncio.sleep(self.config.heartbeat_timeout_s / 2)

            last = self.handler.last_heartbeat_at
            if last is None:
                continue

            silence_s = (datetime.now(UTC) - last).total_seconds()
            if silence_s > self.config.heartbeat_timeout_s:
                log.error("feed stalled", extra={"silence_s": silence_s})
                raise ConnectionError(f"no heartbeat for {silence_s:.1f}s")

    def stop(self) -> None:
        """Signal shutdown. The run loop drains and exits."""
        self._stopping.set()
