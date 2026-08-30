"""Runtime configuration, entirely from the environment.

No config file. The VM startup script and the test suite set the same
variables, so there is one code path rather than a production one and a
"local mode" that quietly diverges from it.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field

COINBASE_WS_URL = "wss://ws-feed.exchange.coinbase.com"

DEFAULT_PRODUCTS = ["BTC-USD", "ETH-USD", "SOL-USD"]
CHANNELS = ["matches", "level2_batch", "heartbeat"]


def _env_list(name: str, default: list[str]) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()] or default


@dataclass(frozen=True)
class Config:
    project_id: str = field(default_factory=lambda: os.environ.get("GCP_PROJECT", ""))
    ws_url: str = field(default_factory=lambda: os.environ.get("WS_URL", COINBASE_WS_URL))
    products: list[str] = field(default_factory=lambda: _env_list("PRODUCTS", DEFAULT_PRODUCTS))

    heartbeat_timeout_s: float = float(os.environ.get("HEARTBEAT_TIMEOUT_S", "10"))
    """A TCP connection can stay open while data stops. Absence of a heartbeat
    for this long is the only way to detect that, so it forces a reconnect."""

    backoff_initial_s: float = float(os.environ.get("BACKOFF_INITIAL_S", "1"))
    backoff_max_s: float = float(os.environ.get("BACKOFF_MAX_S", "60"))
    """Capped exponential backoff. Uncapped, a long outage means the consumer
    is asleep for hours after the feed comes back."""

    ws_max_message_bytes: int = int(os.environ.get("WS_MAX_MESSAGE_BYTES", str(64 * 1024 * 1024)))
    """A full level2 snapshot for a liquid product is several MEGABYTES - the
    whole book, every level. The websockets default cap is 1 MB, so the very
    first message after subscribing closes the connection with code 1009
    (message too big), and the consumer reconnects into the same failure
    forever. 64 MB is generous headroom over the ~5 MB observed."""

    publish_enabled: bool = os.environ.get("PUBLISH_ENABLED", "true").lower() == "true"
    metrics_enabled: bool = os.environ.get("METRICS_ENABLED", "true").lower() == "true"

    def topic(self, channel: str) -> str:
        return f"market.raw.{channel}"
