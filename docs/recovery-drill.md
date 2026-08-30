# Recovery drill

*(Phase 7)* The writeup of the deliberate outage: kill the consumer VM
mid-stream, leave it dead 30 minutes, restart, observe the gap in
`fct_data_quality`, backfill from the lake plus the Coinbase REST trades
endpoint, and prove the marts match the pre-outage snapshot.

This file is the single most convincing artifact in the repository. It is
empty until the drill has actually been run — writing it in advance would be
fiction.
