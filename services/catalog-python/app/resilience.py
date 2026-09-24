"""Application-level resilience primitives that complement the Istio mesh policies.

* ``CircuitBreaker`` – small async breaker (closed → open → half-open) so a failing dependency is skipped fast.
* ``Bulkhead`` – caps concurrent calls to a dependency per worker; callers that cannot get a slot in time fail fast.
* ``db_retry`` – tenacity retry with jittered exponential backoff for transient connection errors (reads only).
"""

import asyncio
import time
from collections.abc import Awaitable, Callable
from enum import StrEnum
from typing import TypeVar

from prometheus_client import Counter, Gauge
from sqlalchemy.exc import DBAPIError, OperationalError
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_random_exponential

T = TypeVar("T")

BREAKER_STATE = Gauge("catalog_circuit_breaker_state", "0=closed 1=half_open 2=open", ["name"], multiprocess_mode="max")
BREAKER_REJECTED = Counter("catalog_circuit_breaker_rejected_total", "Calls rejected by an open breaker", ["name"])
BULKHEAD_REJECTED = Counter("catalog_bulkhead_rejected_total", "Calls rejected by a full bulkhead", ["name"])


class CircuitOpenError(RuntimeError):
    pass


class BulkheadFullError(RuntimeError):
    pass


class State(StrEnum):
    CLOSED = "closed"
    HALF_OPEN = "half_open"
    OPEN = "open"


_STATE_VALUE = {State.CLOSED: 0, State.HALF_OPEN: 1, State.OPEN: 2}


class CircuitBreaker:
    def __init__(
        self,
        name: str,
        failure_threshold: int = 5,
        recovery_timeout: float = 30.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.name = name
        self.failure_threshold = failure_threshold
        self.recovery_timeout = recovery_timeout
        self._clock = clock
        self._failures = 0
        self._opened_at = 0.0
        self._half_open_probe = False
        self._set(State.CLOSED)

    @property
    def state(self) -> State:
        if self._state is State.OPEN and self._clock() - self._opened_at >= self.recovery_timeout:
            self._set(State.HALF_OPEN)
        return self._state

    def _set(self, state: State) -> None:
        self._state = state
        BREAKER_STATE.labels(self.name).set(_STATE_VALUE[state])

    async def call(self, fn: Callable[[], Awaitable[T]]) -> T:
        state = self.state
        if state is State.OPEN or (state is State.HALF_OPEN and self._half_open_probe):
            BREAKER_REJECTED.labels(self.name).inc()
            raise CircuitOpenError(f"circuit '{self.name}' is open")
        if state is State.HALF_OPEN:
            self._half_open_probe = True  # allow exactly one trial call
        try:
            result = await fn()
        except Exception:
            self._on_failure()
            raise
        self._on_success()
        return result

    def _on_success(self) -> None:
        self._failures = 0
        self._half_open_probe = False
        if self._state is not State.CLOSED:
            self._set(State.CLOSED)

    def _on_failure(self) -> None:
        self._failures += 1
        self._half_open_probe = False
        if self._state is State.HALF_OPEN or self._failures >= self.failure_threshold:
            self._opened_at = self._clock()
            self._set(State.OPEN)


class Bulkhead:
    def __init__(self, name: str, max_concurrency: int, max_wait: float = 1.0) -> None:
        self.name = name
        self._sem = asyncio.Semaphore(max_concurrency)
        self._max_wait = max_wait

    async def call(self, fn: Callable[[], Awaitable[T]]) -> T:
        try:
            async with asyncio.timeout(self._max_wait):
                await self._sem.acquire()
        except TimeoutError as exc:
            BULKHEAD_REJECTED.labels(self.name).inc()
            raise BulkheadFullError(f"bulkhead '{self.name}' is full") from exc
        try:
            return await fn()
        finally:
            self._sem.release()


def _is_transient_db_error(exc: BaseException) -> bool:
    if isinstance(exc, OperationalError):
        return True
    if isinstance(exc, DBAPIError) and exc.connection_invalidated:
        return True
    return isinstance(exc, ConnectionError | TimeoutError)


# 3 attempts, full-jitter exponential backoff capped at 1s. Istio also retries at the HTTP layer, so keep this small
# to avoid retry amplification.
db_retry = retry(
    retry=retry_if_exception(_is_transient_db_error),
    wait=wait_random_exponential(multiplier=0.1, max=1.0),
    stop=stop_after_attempt(3),
    reraise=True,
)
