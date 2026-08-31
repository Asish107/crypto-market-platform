"""Custom metrics to Cloud Monitoring.

These are the numbers the §10 alert policies fire on. Counters are kept in
process and flushed periodically rather than written per message - one API
call per trade would cost more than the rest of the platform combined.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

log = logging.getLogger(__name__)

METRIC_PREFIX = "custom.googleapis.com/market"


@dataclass
class Counters:
    """In-process tallies, flushed on an interval."""

    messages_received: dict[str, int] = field(default_factory=dict)
    sequence_gaps_total: int = 0
    heartbeat_detected_gaps_total: int = 0
    """Gaps found by comparing heartbeat last_trade_id against what we saw -
    trades that never arrived as messages at all."""

    messages_lost_total: int = 0
    duplicates_total: int = 0
    websocket_reconnects_total: int = 0
    book_resets_total: int = 0
    crossed_books_total: int = 0
    publish_errors_total: int = 0

    ingest_lag_samples_ms: list[float] = field(default_factory=list)

    def record_message(self, channel: str) -> None:
        self.messages_received[channel] = self.messages_received.get(channel, 0) + 1

    def record_lag(self, lag_ms: float) -> None:
        # Bounded so a long run cannot grow this without limit. Percentiles are
        # computed per flush window, which is what the alert cares about.
        self.ingest_lag_samples_ms.append(lag_ms)
        if len(self.ingest_lag_samples_ms) > 10_000:
            del self.ingest_lag_samples_ms[:5_000]

    def lag_percentile(self, pct: float) -> float | None:
        if not self.ingest_lag_samples_ms:
            return None
        ordered = sorted(self.ingest_lag_samples_ms)
        idx = min(int(len(ordered) * pct), len(ordered) - 1)
        return ordered[idx]

    def snapshot(self) -> dict[str, float]:
        """Flatten to the metric names the dashboard and alerts use."""
        out: dict[str, float] = {
            "sequence_gaps_total": self.sequence_gaps_total,
            "heartbeat_detected_gaps_total": self.heartbeat_detected_gaps_total,
            "messages_lost_total": self.messages_lost_total,
            "duplicates_total": self.duplicates_total,
            "websocket_reconnects_total": self.websocket_reconnects_total,
            "book_resets_total": self.book_resets_total,
            "crossed_books_total": self.crossed_books_total,
            "publish_errors_total": self.publish_errors_total,
        }
        for channel, count in self.messages_received.items():
            out[f"messages_received.{channel}"] = count
        for pct, name in ((0.5, "p50"), (0.95, "p95"), (0.99, "p99")):
            value = self.lag_percentile(pct)
            if value is not None:
                out[f"ingest_lag_ms.{name}"] = value
        return out


# Cloud Monitoring rejects two points on the same time series less than 10
# seconds apart. The periodic flusher and the shutdown drain can easily land in
# the same second, which fails the ENTIRE write - including the metrics that
# were fine.
MIN_WRITE_INTERVAL_S = 10.0


class MetricsReporter:
    """Writes counters to Cloud Monitoring, or to logs when disabled.

    Logging is the honest fallback for local runs: the numbers still exist and
    are still visible, they just are not billed.
    """

    def __init__(self, project_id: str, enabled: bool = True) -> None:
        self.project_id = project_id
        self.enabled = enabled and bool(project_id)
        self.counters = Counters()
        self._last_write_at = 0.0

    def flush(self, force: bool = False) -> None:
        snapshot = self.counters.snapshot()
        if not snapshot:
            return

        now = time.time()
        if self.enabled and not force and (now - self._last_write_at) < MIN_WRITE_INTERVAL_S:
            # Too soon for Monitoring to accept another point. Dropping this
            # write loses nothing: these are cumulative totals, so the next
            # flush carries the same information.
            log.debug("metrics flush skipped, too soon since last write")
            return

        if not self.enabled:
            log.info("metrics", extra={"metrics": snapshot})
            return

        try:
            self._write(snapshot)
        except Exception as exc:
            log.warning("metrics flush failed", extra={"error": str(exc)})

    def _write(self, snapshot: dict[str, float]) -> None:
        from google.cloud import monitoring_v3

        client = monitoring_v3.MetricServiceClient()
        project = f"projects/{self.project_id}"
        interval = monitoring_v3.types.TimeInterval({"end_time": {"seconds": int(time.time())}})

        series_batch = []
        for name, value in snapshot.items():
            series = monitoring_v3.types.TimeSeries()
            series.metric.type = f"{METRIC_PREFIX}/{name.replace('.', '_')}"
            series.resource.type = "global"
            series.points = [
                monitoring_v3.types.Point(
                    {"interval": interval, "value": {"double_value": float(value)}}
                )
            ]
            series_batch.append(series)

        client.create_time_series(name=project, time_series=series_batch)
