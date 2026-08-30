# Recorded WebSocket fixtures

`session_with_faults.jsonl` is a captured-shape Coinbase session with faults
deliberately injected, one message per line. It is the input to
`test_replay.py`, which asserts the consumer behaves correctly under each.

Message shapes match the live feed as verified against
`wss://ws-feed.exchange.coinbase.com`, including two details that are easy to
get wrong from the docs alone:

- **`l2update` carries no `sequence` field.** Only `match`, `last_match` and
  `heartbeat` do.
- **`sequence` is not contiguous on these channels.** It counts every
  order-book event for the product, most of which arrive on the `full` channel
  we do not subscribe to, so it jumps by hundreds between consecutive trades.
  `trade_id` is the contiguous counter, and it is what gap detection uses.

The faults:

| Line(s) | Fault | Correct behaviour |
|---|---|---|
| 1-6 | clean subscribe, snapshot, trades | book ready, no gaps |
| 7 | **trade_id gap** (503 -> 507) | gap counted, 3 trades recorded lost |
| 8 | **duplicate trade** (replayed 507) | counted as duplicate, not a gap |
| 9 | **heartbeat ahead of us** (`last_trade_id` 510) | 3 further trades detected as never delivered |
| 10-11 | l2 updates incl. a size-0 removal | level removed, not zeroed |
| 12 | **disconnect marker** | books invalidated, continuity reset |
| 13 | l2 update arriving before the new snapshot | **dropped**, not applied to stale book |
| 14 | fresh snapshot after reconnect | book usable again |
| 15 | trade at a distant trade_id | **no phantom gap** after reset |

The disconnect marker (`{"type":"__disconnect__"}`) is a test-harness
construct, not a Coinbase message type. Recording a real TCP drop in a JSONL
file is not possible, and the alternative - standing up a fake WebSocket
server - would test the plumbing rather than the logic.
