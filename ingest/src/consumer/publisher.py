"""Pub/Sub publishing with per-product ordering.

Two properties matter here:

1. `ordering_key = product_id` - Pub/Sub guarantees ordered delivery per key,
   which is what the sequence and book logic downstream assume. Without it the
   broker is free to reorder and the deltas become nonsense.

2. Publishing is fire-and-forget with an error callback. Blocking the socket
   reader on a publish round-trip would build backpressure into the WebSocket
   and cause the very message loss this project exists to measure.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from concurrent.futures import Future
from typing import Any, Protocol

log = logging.getLogger(__name__)


class Publisher(Protocol):
    """Narrow interface so tests can substitute a recorder for the real client."""

    def publish(self, channel: str, payload: dict[str, Any], ordering_key: str) -> None: ...

    def flush(self) -> None: ...


class PubSubPublisher:
    """The real thing. Wraps google-cloud-pubsub."""

    def __init__(self, project_id: str, topic_for: Callable[[str], str]) -> None:
        # google-cloud-pubsub ships partial stubs that do not describe the
        # namespace package, so mypy cannot resolve this import. The wrapper
        # around it is fully typed, which is where the value is.
        from google.cloud import pubsub_v1  # type: ignore[attr-defined]

        # Ordering is per (topic, key) and must be enabled at publisher level.
        self._client = pubsub_v1.PublisherClient(
            publisher_options=pubsub_v1.types.PublisherOptions(enable_message_ordering=True)
        )
        self._project_id = project_id
        self._topic_for = topic_for
        self.published_total = 0
        self.errors_total = 0

    def _topic_path(self, channel: str) -> str:
        path: str = self._client.topic_path(self._project_id, self._topic_for(channel))
        return path

    def publish(self, channel: str, payload: dict[str, Any], ordering_key: str) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode()
        future: Future[str] = self._client.publish(
            self._topic_path(channel), data, ordering_key=ordering_key
        )
        future.add_done_callback(lambda f: self._on_done(f, channel, ordering_key))
        self.published_total += 1

    def _on_done(self, future: Future[str], channel: str, ordering_key: str) -> None:
        exc = future.exception()
        if exc is None:
            return

        self.errors_total += 1
        # An ordering key is paused after a failure until explicitly resumed,
        # otherwise every later message for that product is silently dropped.
        log.error(
            "publish failed",
            extra={"channel": channel, "ordering_key": ordering_key, "error": str(exc)},
        )
        self._client.resume_publish(self._topic_path(channel), ordering_key)

    def flush(self) -> None:
        """Block until every queued message is sent. Called on SIGTERM."""
        self._client.stop()


class RecordingPublisher:
    """Test double. Keeps what was published so assertions can inspect it."""

    def __init__(self) -> None:
        self.messages: list[tuple[str, dict[str, Any], str]] = []
        self.flushed = False

    def publish(self, channel: str, payload: dict[str, Any], ordering_key: str) -> None:
        self.messages.append((channel, payload, ordering_key))

    def flush(self) -> None:
        self.flushed = True

    def for_channel(self, channel: str) -> list[dict[str, Any]]:
        return [p for c, p, _ in self.messages if c == channel]
