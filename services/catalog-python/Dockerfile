# syntax=docker/dockerfile:1.7
# ---- build: resolve wheels into a self-contained virtualenv -------------------------------------------------------
FROM python:3.12-slim AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt

# ---- runtime ------------------------------------------------------------------------------------------------------
FROM python:3.12-slim
ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="catalog" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/mahmoud-araby/microk8s-onperm"
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
WORKDIR /app
COPY gunicorn.conf.py ./
COPY app ./app
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    APP_VERSION=${APP_VERSION} \
    WEB_CONCURRENCY=2 \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus \
    TMPDIR=/tmp
# Non-root, read-only root FS friendly: only /tmp (emptyDir) is written (prometheus multiprocess files).
USER 10001:10001
EXPOSE 8080
# exec form: gunicorn is PID 1 and receives SIGTERM directly (graceful_timeout=25s).
ENTRYPOINT ["gunicorn", "--config", "gunicorn.conf.py"]
