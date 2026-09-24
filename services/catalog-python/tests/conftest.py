import uuid

import httpx
import pytest
from fakeredis import FakeAsyncRedis

from app.cache import ProductCache
from app.config import Settings
from app.main import create_app
from app.resilience import Bulkhead, CircuitBreaker
from app.service import ProductService


class FakeRepository:
    """In-memory, tenant-scoped stand-in for ProductRepository."""

    def __init__(self) -> None:
        self.rows: dict[tuple[str, uuid.UUID], dict] = {}
        self.get_calls = 0
        self.fail = False

    async def get(self, tenant, product_id):
        self.get_calls += 1
        if self.fail:
            raise ConnectionError("db down")
        return self.rows.get((tenant, product_id))

    async def list(self, tenant, limit, offset):
        return [v for (t, _), v in self.rows.items() if t == tenant][offset : offset + limit]

    async def create(self, tenant, data):
        pid = uuid.uuid4()
        row = {"id": str(pid), **data, "price": float(data["price"])}
        self.rows[(tenant, pid)] = row
        return row

    async def adjust_stock(self, tenant, product_id, delta):
        self.rows[(tenant, product_id)]["stock"] += delta

    async def ping(self):
        if self.fail:
            raise ConnectionError("db down")


@pytest.fixture
def repo() -> FakeRepository:
    return FakeRepository()


@pytest.fixture
def redis() -> FakeAsyncRedis:
    return FakeAsyncRedis()


@pytest.fixture
def app(repo, redis):
    application = create_app(Settings(tenant_id="shared", otel_exporter_otlp_endpoint=None))
    application.state.service = ProductService(
        repo, ProductCache(redis, "t:"), Bulkhead("postgres", 5), CircuitBreaker("postgres", 3, 30)
    )
    application.state.started = True
    return application


@pytest.fixture
async def client(app):
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://catalog") as c:
        yield c
