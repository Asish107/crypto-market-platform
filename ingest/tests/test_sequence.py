"""Continuity detection: the only evidence that data went missing.

Keyed on trade_id, not sequence - see consumer/sequence.py for why sequence
does not work on the channels we subscribe to.
"""

from consumer.sequence import Continuity, ContinuityTracker


def test_first_message_establishes_baseline_without_reporting_a_gap() -> None:
    t = ContinuityTracker()
    obs = t.observe("BTC-USD", 1000)
    assert obs.continuity is Continuity.FIRST
    assert obs.missing == 0
    assert t.gaps_total == 0


def test_consecutive_trade_ids_are_in_order() -> None:
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    for trade_id in (1001, 1002, 1003):
        assert t.observe("BTC-USD", trade_id).continuity is Continuity.IN_ORDER
    assert t.gaps_total == 0


def test_a_skipped_trade_id_is_a_gap_and_counts_the_lost_trades() -> None:
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    obs = t.observe("BTC-USD", 1003)

    assert obs.continuity is Continuity.GAP
    assert obs.is_loss
    assert obs.missing == 2  # 1001 and 1002 are gone
    assert t.gaps_total == 1
    assert t.messages_lost_total == 2


def test_a_gap_advances_the_baseline_so_it_is_reported_once_not_forever() -> None:
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    t.observe("BTC-USD", 1003)
    assert t.observe("BTC-USD", 1004).continuity is Continuity.IN_ORDER
    assert t.gaps_total == 1


def test_replayed_trade_is_a_duplicate_not_a_gap() -> None:
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    t.observe("BTC-USD", 1001)
    obs = t.observe("BTC-USD", 1001)

    assert obs.continuity is Continuity.DUPLICATE
    assert not obs.is_loss
    assert t.duplicates_total == 1


def test_duplicate_does_not_rewind_the_baseline() -> None:
    """The bug this guards: a replayed old message resetting the high-water
    mark, so every subsequent message reads as a huge phantom gap."""
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    t.observe("BTC-USD", 1005)
    t.observe("BTC-USD", 1001)  # late straggler

    assert t.last_seen("BTC-USD") == 1005
    assert t.observe("BTC-USD", 1006).continuity is Continuity.IN_ORDER


def test_products_are_tracked_independently() -> None:
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    t.observe("ETH-USD", 5000)

    assert t.observe("BTC-USD", 1001).continuity is Continuity.IN_ORDER
    assert t.observe("ETH-USD", 5001).continuity is Continuity.IN_ORDER
    assert t.gaps_total == 0


def test_reset_after_reconnect_prevents_a_phantom_gap() -> None:
    """The exchange replays and may resume anywhere after a reconnect.
    Without a reset that jump is indistinguishable from real data loss."""
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)

    t.reset("BTC-USD")
    obs = t.observe("BTC-USD", 9_000_000)

    assert obs.continuity is Continuity.FIRST
    assert t.gaps_total == 0
    assert t.messages_lost_total == 0


def test_without_reset_a_reconnect_would_report_a_massive_gap() -> None:
    """Documents precisely what reset() is protecting against."""
    t = ContinuityTracker()
    t.observe("BTC-USD", 1000)
    obs = t.observe("BTC-USD", 9_000_000)

    assert obs.continuity is Continuity.GAP
    assert obs.missing == 8_998_999
