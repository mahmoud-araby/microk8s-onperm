"""Product use cases: cache-aside reads, bulkhead + circuit breaker around the database."""

import uuid
from collections.abc import Awaitable, Callable
from typing import Any

from app.cache import ProductCache
from app.resilience import Bulkhead, CircuitBreaker


class ProductService:
    def __init__(self, repository: Any, cache: ProductCache, bulkhead: Bulkhead, breaker: CircuitBreaker) -> None:
        self.repository = repository
        self.cache = cache
        self._bulkhead = bulkhead
        self._breaker = breaker

    async def _db(self, fn: Callable[[], Awaitable[Any]]) -> Any:
        # Bulkhead outside the breaker: overload (rejections) must not trip the breaker.
        return await self._bulkhead.call(lambda: self._breaker.call(fn))

    def _key(self, tenant: str, product_id: uuid.UUID) -> str:
        return self.cache.key(tenant, "product", str(product_id))

    async def get(self, tenant: str, product_id: uuid.UUID) -> dict | None:
        return await self.cache.get_or_load(
            self._key(tenant, product_id), lambda: self._db(lambda: self.repository.get(tenant, product_id))
        )

    async def list(self, tenant: str, limit: int, offset: int) -> list[dict]:
        return await self._db(lambda: self.repository.list(tenant, limit, offset))

    async def create(self, tenant: str, data: dict) -> dict:
        product = await self._db(lambda: self.repository.create(tenant, data))
        await self.cache.set(self._key(tenant, uuid.UUID(product["id"])), product)
        return product

    async def adjust_stock(self, tenant: str, product_id: uuid.UUID, delta: int) -> None:
        await self._db(lambda: self.repository.adjust_stock(tenant, product_id, delta))
        await self.cache.invalidate(self._key(tenant, product_id))

    async def db_ping(self) -> None:
        await self.repository.ping()
