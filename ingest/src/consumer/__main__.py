"""Entry point. Wires the pieces together and handles shutdown.

Run locally without touching GCP:

    PUBLISH_ENABLED=false METRICS_ENABLED=false python -m consumer
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import signal

from consumer import logs
from consumer.config import Config
from consumer.metrics import MetricsReporter
from consumer.publisher import Publisher, PubSubPublisher, RecordingPublisher
from consumer.ws_client import MessageHandler, WebSocketConsumer

log = logging.getLogger("consumer")

METRICS_FLUSH_INTERVAL_S = 60


def build_publisher(config: Config) -> Publisher:
    if not config.publish_enabled:
        log.warning("PUBLISH_ENABLED=false - messages will be discarded")
        return RecordingPublisher()
    return PubSubPublisher(config.project_id, config.topic)


async def flush_metrics_periodically(metrics: MetricsReporter, stop: asyncio.Event) -> None:
    while not stop.is_set():
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(stop.wait(), timeout=METRICS_FLUSH_INTERVAL_S)
        metrics.flush()


async def main() -> int:
    logs.configure()

    config = Config()
    if config.publish_enabled and not config.project_id:
        log.error("GCP_PROJECT is required when PUBLISH_ENABLED=true")
        return 2

    metrics = MetricsReporter(config.project_id, enabled=config.metrics_enabled)
    publisher = build_publisher(config)
    handler = MessageHandler(config, publisher, metrics)
    consumer = WebSocketConsumer(config, handler)

    stop = asyncio.Event()

    def request_stop(signame: str) -> None:
        # Graceful drain: stop reading, flush what is already queued, exit.
        # A hard kill loses whatever Pub/Sub has not acknowledged.
        log.info("shutdown requested", extra={"signal": signame})
        consumer.stop()
        stop.set()

    loop = asyncio.get_running_loop()
    for signame in ("SIGTERM", "SIGINT"):
        loop.add_signal_handler(getattr(signal, signame), request_stop, signame)

    flusher = asyncio.create_task(flush_metrics_periodically(metrics, stop))
    try:
        await consumer.run()
    finally:
        stop.set()
        await flusher
        publisher.flush()
        metrics.flush()
        log.info("drained", extra=metrics.counters.snapshot())

    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
