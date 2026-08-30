"""Structured JSON logging for Cloud Logging.

Cloud Logging parses a JSON line on stdout into a structured entry, so
`log.warning("gap", extra={"missing": 3})` becomes a queryable field rather
than text someone has to grep.

Written as a real formatter because the naive approach - a `%`-style format
string with the fields hardcoded - silently discards every `extra` that is not
named in it. That failure mode cost a debugging round during Phase 2: the
consumer logged "connection lost" with no reason attached, because the reason
lived in an `extra` the format string never mentioned.
"""

from __future__ import annotations

import json
import logging
import sys
from typing import Any

# Attributes LogRecord always carries; anything else was passed via `extra`.
_STANDARD = frozenset(
    """args asctime created exc_info exc_text filename funcName levelname levelno
    lineno module msecs message msg name pathname process processName relativeCreated
    stack_info thread threadName taskName""".split()
)


class CloudLoggingFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "severity": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
        }

        for key, value in record.__dict__.items():
            if key not in _STANDARD and not key.startswith("_"):
                payload[key] = value if isinstance(value, str | int | float | bool) else str(value)

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)

        return json.dumps(payload, default=str)


def configure(level: int = logging.INFO) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(CloudLoggingFormatter())
    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level)
