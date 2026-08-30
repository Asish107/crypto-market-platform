"""Coinbase market data WebSocket consumer.

ws_client.py  asyncio client, reconnect with backoff, heartbeat watchdog,
              and MessageHandler - the pure message-routing logic
book.py       L2 snapshot + delta state machine
sequence.py   per-product gap detection
publisher.py  Pub/Sub publish with product_id as ordering key
metrics.py    Cloud Monitoring custom metrics
config.py     environment-driven settings
"""

__all__ = [
    "book",
    "config",
    "metrics",
    "publisher",
    "sequence",
    "ws_client",
]
