# Job submission happens from here, not from a laptop. Apache Beam has no
# wheels for macOS/ARM on recent Pythons and falls back to a source build that
# does not complete; a Linux container gets the prebuilt wheel in seconds.
#
# Python 3.11 deliberately: it is the version Dataflow's own worker images are
# built on for this SDK release, and a mismatch between submitter and worker
# shows up as pickling errors deep in a running job rather than at submit time.
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl gnupg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY bars_pipeline.py .

ENTRYPOINT ["python", "bars_pipeline.py"]
