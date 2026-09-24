"""Redis cache-aside with TTL jitter and stampede protection (per-key lock), degrading gracefully when Redis fails."""

import asyncio
import json
import random
import uuid
from collections.abc import Awaitable, Callable
from typing import Any

import structlog
from prometheus_client import Counter
from redis.asyncio import Redis

from app.resilience import CircuitBreaker

log = structlog.get_logger(__name__)

CACHE_REQUESTS = Counter("catalog_cache_requests_total", "Cache lookups", ["result"])  # hit | miss | error

_RELEASE_LOCK = """
if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end
"""
_UNAVAILABLE = object()


class ProductCache:
    def __init__(
        self,
        redis: Redis,
        key_prefix: str = "",
        ttl_seconds: int = 300,
        lock_ttl_ms: int = 5000,
        wait_for_fill: float = 1.0,
        breaker: CircuitBreaker | None = None,
    ) -> None:
        self._redis = redis
        self._prefix = key_prefix
        self._ttl = ttl_seconds
        self._lock_ttl_ms = lock_ttl_ms
        self._wait_for_fill = wait_for_fill
        self._breaker = breaker or CircuitBreaker("redis", failure_threshold=5, recovery_timeout=15)

    def key(self, *parts: str) -> str:
        return self._prefix + ":".join(parts)

    async def _safe(self, op: Callable[[], Awaitable[Any]]) -> Any:
        """Run a Redis op through the breaker; any failure means 'cache unavailable', never a request error."""
        try:
            return await self._breaker.call(op)
        except Exception as exc:  # noqa: BLE001 - cache is best effort
            CACHE_REQUESTS.labels("error").inc()
            log.debug("cache unavailable", error=str(exc))
            return _UNAVAILABLE

    async def get_or_load(self, key: str, loader: Callable[[], Awaitable[dict | None]]) -> dict | None:
        cached = await self._safe(lambda: self._redis.get(key))
        if cached is _UNAVAILABLE:
            return await loader()
        if cached is not None:
            CACHE_REQUESTS.labels("hit").inc()
            return json.loads(cached)
        CACHE_REQUESTS.labels("miss").inc()

        # Stampede protection: only the lock holder hits the database; others briefly wait for the fill.
        lock_key, token = f"{key}:lock", uuid.uuid4().hex
        acquired = await self._safe(lambda: self._redis.set(lock_key, token, nx=True, px=self._lock_ttl_ms))
        if acquired is None:  # someone else is loading
            filled = await self._wait_for(key)
            if filled is not None:
                return filled
        try:
            value = await loader()
            if value is not None:
                await self.set(key, value)
            return value
        finally:
            if acquired is True:
                await self._safe(lambda: self._redis.eval(_RELEASE_LOCK, 1, lock_key, token))

    async def _wait_for(self, key: str) -> dict | None:
        deadline = asyncio.get_running_loop().time() + self._wait_for_fill
        while asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.05)
            cached = await self._safe(lambda: self._redis.get(key))
            if cached is _UNAVAILABLE:
                return None
            if cached is not None:
                CACHE_REQUESTS.labels("hit").inc()
                return json.loads(cached)
        return None

    async def set(self, key: str, value: dict) -> None:
        ttl = int(self._ttl * random.uniform(0.9, 1.1))  # noqa: S311 - jitter avoids synchronized expiry
        await self._safe(lambda: self._redis.set(key, json.dumps(value), ex=ttl))

    async def invalidate(self, key: str) -> None:
        await self._safe(lambda: self._redis.delete(key))

    async def ping(self) -> bool:
        return await self._safe(lambda: self._redis.ping()) is True
