"""Optional Kafka consumer for inventory events (KAFKA_ENABLED=true): adjusts stock and invalidates the cache."""

import asyncio
import contextlib
import json
import uuid

import structlog
from aiokafka import AIOKafkaConsumer
from opentelemetry import propagate, trace

from app.config import Settings
from app.service import ProductService

log = structlog.get_logger(__name__)
tracer = trace.get_tracer(__name__)


class InventoryConsumer:
    def __init__(self, settings: Settings, service: ProductService) -> None:
        self._settings = settings
        self._service = service
        self._task: asyncio.Task | None = None
        self._consumer: AIOKafkaConsumer | None = None
        self.connected = False

    async def start(self) -> None:
        self._task = asyncio.create_task(self._run(), name="inventory-consumer")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task

    async def _run(self) -> None:
        backoff = 1.0
        while True:
            self._consumer = AIOKafkaConsumer(
                self._settings.inventory_topic,
                bootstrap_servers=self._settings.kafka_bootstrap_servers,
                group_id=self._settings.consumer_group,
                enable_auto_commit=False,
                auto_offset_reset="earliest",
                **self._settings.kafka_client_options(),
            )
            try:
                await self._consumer.start()
                self.connected, backoff = True, 1.0
                log.info("kafka consumer started", topic=self._settings.inventory_topic)
                async for msg in self._consumer:
                    await self._handle(msg)
                    await self._consumer.commit()
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - reconnect with backoff
                log.warning("kafka consumer error, reconnecting", error=str(exc), backoff=backoff)
            finally:
                self.connected = False
                with contextlib.suppress(Exception):
                    await self._consumer.stop()
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)

    async def _handle(self, msg) -> None:
        headers = {k: v.decode() for k, v in (msg.headers or []) if v is not None}
        ctx = propagate.extract(headers)
        with (
            tracer.start_as_current_span(f"{msg.topic} process", context=ctx, kind=trace.SpanKind.CONSUMER),
            structlog.contextvars.bound_contextvars(correlation_id=headers.get("x-correlation-id")),
        ):
            try:
                event = json.loads(msg.value)
                tenant = headers.get("x-tenant-id") or event.get("tenantId") or self._settings.tenant_id
                if event.get("eventType") == "StockAdjusted":
                    await self._service.adjust_stock(tenant, uuid.UUID(event["productId"]), int(event["delta"]))
            except (ValueError, KeyError, TypeError) as exc:
                # Poison message: log and skip (commit) instead of blocking the partition.
                log.error("skipping invalid inventory event", offset=msg.offset, error=str(exc))
