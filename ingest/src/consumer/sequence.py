"""Per-product continuity detection.

The feed can drop messages, and when it does nothing errors: no gap in the
timestamps, no reconnect, nothing to notice. The only evidence is a break in a
counter, so this module turns that evidence into an explicit, countable event.

WHICH counter is the entire subtlety, and it is not the obvious one.

Every Coinbase message carries a `sequence`, and the intuitive design tracks
that. It does not work on our channels. `sequence` counts EVERY order-book
event for the product - order received, open, done, change - almost all of
which arrive on the `full` channel we deliberately do not subscribe to.
Measured against `matches` and `heartbeat` alone, it jumps by hundreds
constantly, and the consumer reports catastrophic loss on a perfectly healthy
feed. `l2update` messages carry no `sequence` at all.

`trade_id` is the counter that works: strictly contiguous, +1 per trade,
verified against the live feed. A break in it is real, unambiguous trade loss.

This module is pure - no I/O, no clock, no network - so gaps, duplicates and
reconnect resets are all trivially testable.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class Continuity(Enum):
    """What one observed sequence number means relative to what came before."""

    FIRST = "first"
    """First value seen for this product. Establishes the baseline."""

    IN_ORDER = "in_order"
    """Exactly the value we expected. The overwhelmingly common case."""

    GAP = "gap"
    """Counter jumped forward. Trades were lost - this is real data loss."""

    DUPLICATE = "duplicate"
    """Value at or behind the last seen. Expected after a reconnect, when the
    exchange replays. Harmless here; deduped downstream by trade_id."""


@dataclass(frozen=True)
class Observation:
    """The verdict on a single message."""

    product_id: str
    value: int
    """The trade_id observed."""

    continuity: Continuity
    missing: int = 0
    """How many trades were skipped. Non-zero only for GAP."""

    @property
    def is_loss(self) -> bool:
        return self.continuity is Continuity.GAP


@dataclass
class ContinuityTracker:
    """Tracks the highest trade_id seen per product.

    Not thread-safe by design: one tracker belongs to one consumer task, and
    the WebSocket delivers messages serially anyway. Sharing one across tasks
    would be a bug, so it is not made to look safe.
    """

    _last: dict[str, int] = field(default_factory=dict)
    gaps_total: int = 0
    messages_lost_total: int = 0
    duplicates_total: int = 0

    def observe(self, product_id: str, value: int) -> Observation:
        last = self._last.get(product_id)

        if last is None:
            self._last[product_id] = value
            return Observation(product_id, value, Continuity.FIRST)

        if value <= last:
            # Not advancing the baseline is the point: a replayed old message
            # must not make the tracker believe the stream went backwards.
            self.duplicates_total += 1
            return Observation(product_id, value, Continuity.DUPLICATE)

        missing = value - last - 1
        self._last[product_id] = value

        if missing > 0:
            self.gaps_total += 1
            self.messages_lost_total += missing
            return Observation(product_id, value, Continuity.GAP, missing)

        return Observation(product_id, value, Continuity.IN_ORDER)

    def reset(self, product_id: str) -> None:
        """Forget a product's baseline.

        Called after a reconnect. The exchange replays recent trades and may
        resume anywhere; without this, the first message after every reconnect
        risks being reported as a phantom gap.
        """
        self._last.pop(product_id, None)

    def reset_all(self) -> None:
        self._last.clear()

    def last_seen(self, product_id: str) -> int | None:
        return self._last.get(product_id)
