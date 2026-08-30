"""Order book reconstruction. Wrong here means every spread is wrong."""

from decimal import Decimal

import pytest
from consumer.book import BookSet, CrossedBookError, OrderBook

SNAPSHOT_BIDS = [("100.00", "1.0"), ("99.00", "2.0"), ("98.00", "3.0")]
SNAPSHOT_ASKS = [("101.00", "1.5"), ("102.00", "2.5"), ("103.00", "3.5")]


def book_with_snapshot() -> OrderBook:
    b = OrderBook("BTC-USD")
    b.apply_snapshot(SNAPSHOT_BIDS, SNAPSHOT_ASKS)
    return b


def test_book_is_not_ready_before_a_snapshot() -> None:
    b = OrderBook("BTC-USD")
    assert not b.ready
    assert b.quote() is None


def test_snapshot_makes_the_book_ready_and_sets_top_of_book() -> None:
    b = book_with_snapshot()
    assert b.ready
    quote = b.quote()
    assert quote is not None
    assert quote.bid_price == Decimal("100.00")
    assert quote.ask_price == Decimal("101.00")
    assert quote.spread == Decimal("1.00")
    assert quote.mid == Decimal("100.50")


def test_spread_bps_is_relative_to_mid() -> None:
    b = book_with_snapshot()
    quote = b.quote()
    assert quote is not None
    # 1.00 / 100.50 * 10000
    assert quote.spread_bps == pytest.approx(Decimal("99.5024875"), rel=Decimal("1e-6"))


def test_deltas_before_a_snapshot_are_dropped_not_applied() -> None:
    """Otherwise the consumer invents a book out of deltas alone - one that
    looks perfectly valid and describes a market that never existed."""
    b = OrderBook("BTC-USD")
    b.apply_updates([("buy", "100.00", "1.0")])
    assert not b.ready
    assert len(b) == 0


def test_update_changes_size_at_an_existing_level() -> None:
    b = book_with_snapshot()
    b.apply_updates([("buy", "100.00", "5.0")])
    assert b.best_bid() == (Decimal("100.00"), Decimal("5.0"))


def test_update_adds_a_new_best_level() -> None:
    b = book_with_snapshot()
    b.apply_updates([("buy", "100.50", "0.5")])
    assert b.best_bid() == (Decimal("100.50"), Decimal("0.5"))


def test_size_zero_removes_the_level_rather_than_setting_it_to_zero() -> None:
    """The classic L2 bug: treating 0 as a size leaves phantom levels that
    never clear, and top-of-book silently sticks to a price nobody is quoting."""
    b = book_with_snapshot()
    b.apply_updates([("buy", "100.00", "0")])

    best = b.best_bid()
    assert best is not None
    assert best[0] == Decimal("99.00")


def test_removing_every_level_on_one_side_makes_the_quote_unavailable() -> None:
    b = book_with_snapshot()
    b.apply_updates([("sell", p, "0") for p, _ in SNAPSHOT_ASKS])
    assert b.best_ask() is None
    assert b.quote() is None


def test_crossed_book_raises_instead_of_being_served() -> None:
    """A crossed book is never a market condition - it means our
    reconstruction is broken. Failing loudly beats poisoning the marts."""
    b = book_with_snapshot()
    b.apply_updates([("buy", "105.00", "1.0")])  # bid above best ask

    with pytest.raises(CrossedBookError, match="bid 105.00 >= ask 101.00"):
        b.quote()


def test_reset_makes_the_book_unusable_rather_than_stale() -> None:
    b = book_with_snapshot()
    b.reset()
    assert not b.ready
    assert b.quote() is None
    assert len(b) == 0


def test_deltas_after_reset_are_ignored_until_the_new_snapshot() -> None:
    """The reconnect correctness case: deltas that arrive between the drop and
    the fresh snapshot must not be applied to a stale book."""
    b = book_with_snapshot()
    b.reset()
    b.apply_updates([("buy", "200.00", "9.0")])
    assert b.quote() is None

    b.apply_snapshot(SNAPSHOT_BIDS, SNAPSHOT_ASKS)
    quote = b.quote()
    assert quote is not None
    assert quote.bid_price == Decimal("100.00")  # not the ignored 200.00


def test_snapshot_replaces_state_and_does_not_merge_with_it() -> None:
    b = book_with_snapshot()
    b.apply_snapshot([("50.00", "1.0")], [("51.00", "1.0")])
    assert len(b) == 2
    assert b.best_bid() == (Decimal("50.00"), Decimal("1.0"))


def test_depth_within_bps_sums_only_levels_inside_the_band() -> None:
    b = book_with_snapshot()
    # mid = 100.50; 100 bps = 1.005 -> band [99.495, 101.505]
    bid_depth, ask_depth = b.depth_within_bps(100)
    assert bid_depth == Decimal("1.0")  # only 100.00
    assert ask_depth == Decimal("1.5")  # only 101.00


def test_depth_widens_with_the_band() -> None:
    b = book_with_snapshot()
    bid_depth, ask_depth = b.depth_within_bps(300)  # band [97.485, 103.515]
    assert bid_depth == Decimal("6.0")
    assert ask_depth == Decimal("7.5")


def test_bookset_resets_every_product_on_disconnect() -> None:
    books = BookSet(["BTC-USD", "ETH-USD"])
    for p in ("BTC-USD", "ETH-USD"):
        books[p].apply_snapshot(SNAPSHOT_BIDS, SNAPSHOT_ASKS)
    assert books.all_ready

    books.reset_all()
    assert not books.all_ready
    assert not books["BTC-USD"].ready
