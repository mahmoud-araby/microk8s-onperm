import asyncio

import pytest

from app.resilience import Bulkhead, BulkheadFullError, CircuitBreaker, CircuitOpenError, State


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


async def _fail():
    raise ConnectionError("boom")


async def _ok():
    return "ok"


async def test_breaker_opens_then_half_opens_and_closes():
    clock = FakeClock()
    breaker = CircuitBreaker("test", failure_threshold=2, recovery_timeout=10, clock=clock)
    for _ in range(2):
        with pytest.raises(ConnectionError):
            await breaker.call(_fail)
    assert breaker.state is State.OPEN
    with pytest.raises(CircuitOpenError):
        await breaker.call(_ok)

    clock.now = 11
    assert breaker.state is State.HALF_OPEN
    assert await breaker.call(_ok) == "ok"
    assert breaker.state is State.CLOSED


async def test_failed_probe_reopens():
    clock = FakeClock()
    breaker = CircuitBreaker("test2", failure_threshold=1, recovery_timeout=5, clock=clock)
    with pytest.raises(ConnectionError):
        await breaker.call(_fail)
    clock.now = 6
    with pytest.raises(ConnectionError):
        await breaker.call(_fail)
    assert breaker.state is State.OPEN


async def test_bulkhead_rejects_when_full():
    bulkhead = Bulkhead("test", max_concurrency=1, max_wait=0.05)
    release = asyncio.Event()

    async def slow():
        await release.wait()
        return "done"

    first = asyncio.create_task(bulkhead.call(slow))
    await asyncio.sleep(0)
    with pytest.raises(BulkheadFullError):
        await bulkhead.call(_ok)
    release.set()
    assert await first == "done"
