"""Streaming 1-minute bars, computed independently of the batch path.

THE POINT OF THIS FILE is not the bars. dbt already computes them, more
cheaply, from the same source data. The point is that streaming and batch will
DISAGREE, and being able to say precisely where and why is the actual
deliverable (see models/marts/fct_stream_batch_recon.sql).

The three settings that decide how much they disagree:

  window            - fixed 1 minute, matching fct_bars_1m exactly, so the
                      comparison is like for like.

  allowed_lateness  - 30 seconds. A trade whose EVENT time falls in a window
                      the watermark has already passed is late. Inside this
                      grace period the window re-fires with the trade
                      included; outside it, the trade is dropped by streaming
                      and silently kept by batch. This is the single largest
                      source of divergence.

  accumulating      - each firing restates the whole window rather than
                      emitting only what is new. Discarding mode would make
                      the last pane a fragment, and any consumer summing panes
                      would double count.

Run on Dataflow in bursts, not continuously - it is the only expensive piece
in the platform (~$3/hour against a ~$34/month baseline).
"""

from __future__ import annotations

import argparse
import json
import logging
from typing import Any

import apache_beam as beam
from apache_beam.options.pipeline_options import (
    GoogleCloudOptions,
    PipelineOptions,
    SetupOptions,
    StandardOptions,
)
from apache_beam.transforms import window

BARS_SCHEMA = ",".join(
    [
        "product_id:STRING",
        "bar_start:TIMESTAMP",
        "bar_end:TIMESTAMP",
        "open:NUMERIC",
        "high:NUMERIC",
        "low:NUMERIC",
        "close:NUMERIC",
        "volume:NUMERIC",
        "trade_count:INT64",
        "vwap:NUMERIC",
        "first_trade_id:INT64",
        "last_trade_id:INT64",
        "pane_index:INT64",
        "is_final_pane:BOOL",
        "written_at:TIMESTAMP",
    ]
)


class ParseTrade(beam.DoFn):
    """Decode a Pub/Sub message and stamp it with its EXCHANGE event time.

    Using the exchange timestamp rather than arrival time is what makes the
    windowing meaningful: a trade belongs to the minute it happened in, not
    the minute we happened to receive it. It is also what creates late data,
    and therefore the divergence this pipeline exists to measure.
    """

    def process(self, message: bytes) -> Any:
        from datetime import datetime

        try:
            trade = json.loads(message.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            # A malformed message must not kill the job. The topic schema makes
            # this near-impossible, but "near" is doing work in a stream that
            # runs for hours.
            logging.warning("undecodable message dropped")
            return

        event_time = datetime.fromisoformat(trade["event_time"].replace("Z", "+00:00"))
        yield beam.window.TimestampedValue(
            (
                trade["product_id"],
                {
                    "trade_id": int(trade["trade_id"]),
                    "price": float(trade["price"]),
                    "size": float(trade["size"]),
                },
            ),
            event_time.timestamp(),
        )


class BuildBar(beam.DoFn):
    """Aggregate one product-window into a bar.

    Emits pane metadata alongside the numbers. Without `pane_index` and
    `is_final_pane` you cannot tell a bar that was restated after late data
    from one that never moved, and the reconciliation would have nothing to
    explain its own results with.
    """

    def process(
        self,
        element: tuple[str, list[dict[str, Any]]],
        win: Any = beam.DoFn.WindowParam,
        pane: Any = beam.DoFn.PaneInfoParam,
    ) -> Any:
        from datetime import UTC, datetime

        product_id, trades = element
        if not trades:
            return

        # Order by trade_id, not by arrival: trades routinely share a
        # timestamp, and trade_id is the exchange's own authoritative order.
        # This matches fct_bars_1m exactly, so any difference in open/close is
        # a real divergence rather than an artefact of sorting.
        ordered = sorted(trades, key=lambda t: t["trade_id"])
        prices = [t["price"] for t in ordered]
        volume = sum(t["size"] for t in ordered)
        notional = sum(t["price"] * t["size"] for t in ordered)

        # Beam aggregates in float64, and summing sizes produces values like
        # 2.8783071000000007 - sixteen decimal places of binary floating point
        # residue. BigQuery NUMERIC allows nine, and rejects the row outright:
        # the job runs, the bars are correct, and NOTHING is written.
        #
        # The batch path avoids this entirely by casting to NUMERIC in SQL
        # before any arithmetic. Here the arithmetic happens in Python first,
        # so the rounding has to be explicit.
        def q(value: float | None) -> float | None:
            return None if value is None else round(value, 9)

        yield {
            "product_id": product_id,
            "bar_start": win.start.to_utc_datetime().isoformat(),
            "bar_end": win.end.to_utc_datetime().isoformat(),
            "open": q(prices[0]),
            "high": q(max(prices)),
            "low": q(min(prices)),
            "close": q(prices[-1]),
            "volume": q(volume),
            "trade_count": len(ordered),
            "vwap": q(notional / volume) if volume else None,
            "first_trade_id": ordered[0]["trade_id"],
            "last_trade_id": ordered[-1]["trade_id"],
            "pane_index": pane.index,
            "is_final_pane": pane.is_last,
            "written_at": datetime.now(UTC).isoformat(),
        }


def run(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--output_table", required=True)
    parser.add_argument("--allowed_lateness_seconds", type=int, default=30)
    known, pipeline_argv = parser.parse_known_args(argv)

    options = PipelineOptions(pipeline_argv)
    options.view_as(StandardOptions).streaming = True
    options.view_as(SetupOptions).save_main_session = True

    gcloud = options.view_as(GoogleCloudOptions)
    logging.info("streaming bars -> %s", known.output_table)

    with beam.Pipeline(options=options) as p:
        (
            p
            | "Read" >> beam.io.ReadFromPubSub(subscription=known.subscription)
            | "Parse" >> beam.ParDo(ParseTrade())
            | "Window"
            >> beam.WindowInto(
                window.FixedWindows(60),
                trigger=beam.transforms.trigger.AfterWatermark(
                    # Fire again for each late arrival inside the grace period,
                    # so a bar is corrected rather than left wrong.
                    late=beam.transforms.trigger.AfterCount(1)
                ),
                accumulation_mode=beam.transforms.trigger.AccumulationMode.ACCUMULATING,
                allowed_lateness=known.allowed_lateness_seconds,
            )
            | "Group" >> beam.GroupByKey()
            | "ToList" >> beam.MapTuple(lambda k, v: (k, list(v)))
            | "Build" >> beam.ParDo(BuildBar())
            | "Write"
            >> beam.io.WriteToBigQuery(
                known.output_table,
                schema=BARS_SCHEMA,
                write_disposition=beam.io.BigQueryDisposition.WRITE_APPEND,
                create_disposition=beam.io.BigQueryDisposition.CREATE_IF_NEEDED,
                # Every pane is appended, including restatements. The
                # reconciliation reads the FINAL pane per window; keeping the
                # earlier ones is what makes "how often did a bar change after
                # first firing" an answerable question.
                method=beam.io.WriteToBigQuery.Method.STREAMING_INSERTS,
            )
        )
    _ = gcloud


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()
