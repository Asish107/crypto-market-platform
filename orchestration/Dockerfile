# Dagster code location: the webserver and daemon load the asset graph from
# this image. dbt lives here too, because Dagster shells out to the dbt CLI.
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY orchestration/requirements.txt orchestration-requirements.txt
COPY transform/requirements.txt transform-requirements.txt
RUN pip install --no-cache-dir -r orchestration-requirements.txt -r transform-requirements.txt

COPY transform/ /app/transform/
COPY orchestration/ /app/orchestration/

# Build the dbt manifest at IMAGE BUILD time, not at code load. Parsing on
# every load makes deploys slow and makes the asset graph depend on a
# warehouse connection being reachable at import.
RUN dbt deps --project-dir transform --profiles-dir transform \
 && dbt parse --project-dir transform --profiles-dir transform --target ci || true

ENV PYTHONPATH=/app \
    DAGSTER_HOME=/opt/dagster \
    DBT_TARGET=prod
RUN mkdir -p /opt/dagster

CMD ["dagster", "api", "grpc", "-h", "0.0.0.0", "-p", "4000", "-m", "orchestration.definitions"]
