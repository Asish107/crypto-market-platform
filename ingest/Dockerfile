# Distroless-adjacent slim base. The consumer needs a TLS stack and nothing
# else - no shell in the final image means a compromised process has very
# little to work with.
FROM python:3.12-slim AS base

# Dependencies in their own layer so a code change does not reinstall them.
FROM base AS deps
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM base
WORKDIR /app

# Run as a non-root user. Nothing here needs privileges.
RUN useradd --create-home --shell /usr/sbin/nologin --uid 10001 consumer

COPY --from=deps /install /usr/local
COPY src/ /app/

USER consumer
ENV PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    PUBLISH_ENABLED=true \
    METRICS_ENABLED=true

# SIGTERM triggers the graceful drain in __main__: stop reading, flush queued
# publishes, exit. Docker sends SIGTERM by default, so no STOPSIGNAL needed -
# but the process MUST be PID 1 for it to arrive, hence exec form here.
ENTRYPOINT ["python", "-m", "consumer"]
