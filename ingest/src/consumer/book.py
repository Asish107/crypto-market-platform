"""Level 2 order book state machine.

`level2_batch` gives you one snapshot of the whole book, then only deltas. To
know the best bid at any moment you must hold the entire book in memory and
apply every delta in order. Miss one and the book is quietly wrong from then
on - and so is every spread, depth and liquidity number computed from it.

The failure mode that matters: nothing errors. A book that has drifted looks
exactly like a book that has not. The only defences are (a) refusing to serve
quotes before a snapshot has been applied, and (b) checking the one invariant
that must always hold - the book cannot be crossed.

Prices and sizes are kept as Decimal. Money in binary floating point is a bug
waiting for a big enough number.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from enum import Enum

from sortedcontainers import SortedDict


class Side(Enum):
    BUY = "buy"
    SELL = "sell"


class CrossedBookError(RuntimeError):
    """Best bid >= best ask.

    This is never a market condition; it means our reconstruction is broken.
    Raised loudly rather than served quietly, because a crossed book silently
    poisons every downstream liquidity metric.
    """


@dataclass(frozen=True)
class Quote:
    """Top of book at a point in time."""

    bid_price: Decimal
    bid_size: Decimal
    ask_price: Decimal
    ask_size: Decimal

    @property
    def spread(self) -> Decimal:
        return self.ask_price - self.bid_price

    @property
    def mid(self) -> Decimal:
        return (self.ask_price + self.bid_price) / 2

    @property
    def spread_bps(self) -> Decimal:
        """Spread in basis points of the midpoint - the comparable measure.

        An absolute spread of $1 means something completely different on BTC
        than on SOL, so bps is what any cross-product analysis needs.
        """
        return (self.spread / self.mid) * Decimal(10_000)


class OrderBook:
    """One product's book. Snapshot then deltas, with reconnect handling."""

    def __init__(self, product_id: str) -> None:
        self.product_id = product_id
        # Bids descending, asks ascending, so best is always index 0 - O(log n)
        # updates and O(1) top-of-book, instead of scanning thousands of levels
        # on every one of the ~20 batches per second.
        self._bids: SortedDict[Decimal, Decimal] = SortedDict(lambda p: -p)
        self._asks: SortedDict[Decimal, Decimal] = SortedDict()
        self._ready = False
        self.snapshot_count = 0
        self.update_count = 0

    @property
    def ready(self) -> bool:
        """False until a snapshot has been applied.

        Everything that reads the book must check this. Serving quotes from a
        book built only from deltas produces numbers that look plausible and
        are meaningless.
        """
        return self._ready

    def apply_snapshot(
        self,
        bids: list[tuple[str, str]],
        asks: list[tuple[str, str]],
    ) -> None:
        """Replace all state. This is also the reconnect recovery path."""
        self._bids.clear()
        self._asks.clear()

        for price, size in bids:
            self._set(self._bids, Decimal(price), Decimal(size))
        for price, size in asks:
            self._set(self._asks, Decimal(price), Decimal(size))

        self._ready = True
        self.snapshot_count += 1

    def apply_updates(self, changes: list[tuple[str, str, str]]) -> None:
        """Apply `l2update` deltas: (side, price, size).

        A size of zero means the level is gone, not that it holds zero. Getting
        this wrong leaves phantom levels in the book forever.

        Deltas arriving before a snapshot are dropped, not applied to an empty
        book - that would silently build a fictional book out of thin air.
        """
        if not self._ready:
            return

        for raw_side, raw_price, raw_size in changes:
            side = Side(raw_side)
            book = self._bids if side is Side.BUY else self._asks
            self._set(book, Decimal(raw_price), Decimal(raw_size))

        self.update_count += 1

    @staticmethod
    def _set(book: SortedDict[Decimal, Decimal], price: Decimal, size: Decimal) -> None:
        if size == 0:
            book.pop(price, None)
        else:
            book[price] = size

    def best_bid(self) -> tuple[Decimal, Decimal] | None:
        if not self._ready or not self._bids:
            return None
        price = self._bids.keys()[0]
        return price, self._bids[price]

    def best_ask(self) -> tuple[Decimal, Decimal] | None:
        if not self._ready or not self._asks:
            return None
        price = self._asks.keys()[0]
        return price, self._asks[price]

    def quote(self) -> Quote | None:
        """Top of book, or None if the book is not yet usable.

        Raises CrossedBookError if the invariant is violated.
        """
        bid = self.best_bid()
        ask = self.best_ask()
        if bid is None or ask is None:
            return None

        if bid[0] >= ask[0]:
            raise CrossedBookError(
                f"{self.product_id}: bid {bid[0]} >= ask {ask[0]} "
                f"after {self.snapshot_count} snapshots, {self.update_count} updates"
            )

        return Quote(bid_price=bid[0], bid_size=bid[1], ask_price=ask[0], ask_size=ask[1])

    def depth_within_bps(self, bps: int) -> tuple[Decimal, Decimal]:
        """Total size resting within `bps` of the mid, per side.

        This is the honest measure of liquidity: top-of-book size tells you
        almost nothing about what it costs to move real volume.
        """
        quote = self.quote()
        if quote is None:
            return Decimal(0), Decimal(0)

        band = quote.mid * Decimal(bps) / Decimal(10_000)
        floor, ceil = quote.mid - band, quote.mid + band

        bid_depth = sum((s for p, s in self._bids.items() if p >= floor), Decimal(0))
        ask_depth = sum((s for p, s in self._asks.items() if p <= ceil), Decimal(0))
        return bid_depth, ask_depth

    def reset(self) -> None:
        """Invalidate on disconnect.

        Critical: after a reconnect the exchange sends a fresh snapshot, and any
        deltas that arrive before it must not be applied to the stale book. The
        book must go unusable rather than stay plausible-but-wrong.
        """
        self._bids.clear()
        self._asks.clear()
        self._ready = False

    def __len__(self) -> int:
        return len(self._bids) + len(self._asks)


class BookSet:
    """The books for every subscribed product."""

    def __init__(self, product_ids: list[str]) -> None:
        self._books = {p: OrderBook(p) for p in product_ids}

    def __getitem__(self, product_id: str) -> OrderBook:
        return self._books[product_id]

    def reset_all(self) -> None:
        for book in self._books.values():
            book.reset()

    @property
    def all_ready(self) -> bool:
        return all(b.ready for b in self._books.values())
