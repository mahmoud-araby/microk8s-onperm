"""Kubernetes probes: /health/live, /health/ready (dependencies), /health/startup."""

import asyncio

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter(prefix="/health", include_in_schema=False)


def _status(ok: bool, body: dict) -> JSONResponse:
    return JSONResponse({"status": "UP" if ok else "DOWN", **body}, status_code=200 if ok else 503)


@router.get("/live")
async def live() -> JSONResponse:
    # Only proves the event loop is serving requests; never checks dependencies (avoids restart storms).
    return _status(True, {})


@router.get("/startup")
async def startup(request: Request) -> JSONResponse:
    return _status(getattr(request.app.state, "started", False), {})


@router.get("/ready")
async def ready(request: Request) -> JSONResponse:
    """Postgres is critical (not ready without it). Redis and Kafka are reported: the cache degrades to the
    database and the consumer reconnects on its own, so they do not take the pod out of rotation."""
    state = request.app.state
    if not getattr(state, "started", False):
        return _status(False, {"checks": {"startup": "pending"}})

    checks: dict[str, str] = {}
    try:
        async with asyncio.timeout(1.0):
            await state.service.db_ping()
        checks["postgres"] = "UP"
    except Exception:  # noqa: BLE001
        checks["postgres"] = "DOWN"
    checks["redis"] = "UP" if await state.service.cache.ping() else "DEGRADED"
    consumer = getattr(state, "consumer", None)
    if consumer is not None:
        checks["kafka"] = "UP" if consumer.connected else "DEGRADED"
    return _status(checks["postgres"] == "UP", {"checks": checks})
