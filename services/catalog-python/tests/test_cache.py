import asyncio

from fakeredis import FakeAsyncRedis

from app.cache import ProductCache


async def test_stampede_protection_loads_once():
    cache = ProductCache(FakeAsyncRedis(), "t:", wait_for_fill=2.0)
    loads = 0

    async def loader():
        nonlocal loads
        loads += 1
        await asyncio.sleep(0.1)
        return {"id": "1"}

    results = await asyncio.gather(*(cache.get_or_load("t:k", loader) for _ in range(10)))
    assert all(r == {"id": "1"} for r in results)
    assert loads == 1
