"""Gunicorn + Uvicorn workers. SIGTERM → stop accepting → drain for graceful_timeout (25s < 30s grace period)."""

import os
import shutil

from app.logging_setup import logging_config

wsgi_app = "app.main:create_app()"
bind = "0.0.0.0:8080"
workers = int(os.getenv("WEB_CONCURRENCY", "2"))
worker_class = "uvicorn_worker.UvicornWorker"
graceful_timeout = 25
timeout = 30
keepalive = 75  # longer than the Envoy sidecar's upstream idle timeout expectations; avoids 503 UC resets
max_requests = int(os.getenv("GUNICORN_MAX_REQUESTS", "0"))
max_requests_jitter = 500
preload_app = False  # each worker initialises its own OTel exporters, DB pool and Redis client
forwarded_allow_ips = "*"  # only reachable through the Istio sidecar
worker_tmp_dir = "/dev/shm" if os.path.isdir("/dev/shm") else None  # noqa: S108
accesslog = None  # access logs come from Envoy/Kong
errorlog = "-"
logconfig_dict = logging_config(os.getenv("LOG_LEVEL", "INFO"))


def on_starting(server):
    """Reset the prometheus multiprocess directory (lives on the /tmp emptyDir)."""
    path = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
    if path:
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path, exist_ok=True)


def child_exit(server, worker):
    if os.environ.get("PROMETHEUS_MULTIPROC_DIR"):
        from prometheus_client import multiprocess

        multiprocess.mark_process_dead(worker.pid)
