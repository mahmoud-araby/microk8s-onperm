"""Catalog service entrypoint. Gunicorn loads the factory: `app.main:create_app()`."""

from contextlib import asynccontextmanager

import structlog
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from prometheus_fastapi_instrumentator import Instrumentator
from redis.asyncio import Redis
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app import api, health
from app.cache import ProductCache
from app.config import Settings, get_settings
from app.consumer import InventoryConsumer
from app.db import ProductRepository, create_engine, create_schema
from app.logging_setup import configure_logging
from app.middleware import RequestContextMiddleware
from app.resilience import Bulkhead, BulkheadFullError, CircuitBreaker, CircuitOpenError
from app.service import ProductService
from app.telemetry import setup_telemetry, shutdown_telemetry

log = structlog.get_logger(__name__)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level, settings.service_name, settings.app_version)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        engine = create_engine(settings)
        redis = Redis(
            host=settings.redis_host,
            port=settings.redis_port,
            password=settings.redis_password,
            db=settings.redis_db,
            socket_timeout=0.5,
            socket_connect_timeout=0.5,
            health_check_interval=30,
        )
        if settings.environment == "local":
            await create_schema(engine)  # in clusters the chart runs `python -m app.migrate` as an init container
        app.state.service = ProductService(
            ProductRepository(engine),
            ProductCache(redis, settings.redis_key_prefix, settings.cache_ttl_seconds),
            Bulkhead("postgres", settings.bulkhead_max_concurrency),
            CircuitBreaker("postgres", failure_threshold=5, recovery_timeout=15),
        )
        if settings.kafka_enabled:
            app.state.consumer = InventoryConsumer(settings, app.state.service)
            await app.state.consumer.start()
        app.state.started = True
        log.info("catalog started", environment=settings.environment)
        try:
            yield
        finally:
            # SIGTERM: gunicorn stops accepting, drains in-flight requests (graceful_timeout), then we land here.
            log.info("catalog shutting down")
            if getattr(app.state, "consumer", None):
                await app.state.consumer.stop()
            await redis.aclose()
            await engine.dispose()
            shutdown_telemetry(tracer_provider)

    app = FastAPI(title="catalog", version=settings.app_version, lifespan=lifespan)
    app.state.settings = settings
    app.state.started = False
    app.add_middleware(RequestContextMiddleware, default_tenant=settings.tenant_id)
    app.include_router(health.router)
    app.include_router(api.router)

    @app.exception_handler(CircuitOpenError)
    @app.exception_handler(BulkheadFullError)
    @app.exception_handler(SQLAlchemyError)
    @app.exception_handler(OSError)  # ConnectionError / TimeoutError from drivers
    async def unavailable(_: Request, exc: Exception) -> JSONResponse:
        log.warning("dependency unavailable", error=type(exc).__name__)
        return JSONResponse(
            {"detail": "service temporarily unavailable"}, status_code=503, headers={"Retry-After": "2"}
        )

    @app.exception_handler(IntegrityError)
    async def conflict(_: Request, exc: IntegrityError) -> JSONResponse:
        return JSONResponse({"detail": "product with this sku already exists"}, status_code=409)

    # Honours PROMETHEUS_MULTIPROC_DIR (gunicorn workers) automatically.
    Instrumentator(excluded_handlers=["/health/.*", "/metrics"]).instrument(app).expose(
        app, endpoint="/metrics", include_in_schema=False
    )
    tracer_provider = setup_telemetry(app, settings)
    return app
