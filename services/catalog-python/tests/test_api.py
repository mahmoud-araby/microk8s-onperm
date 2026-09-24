import uuid

PRODUCT = {"sku": "sku-1", "name": "Widget", "price": "19.99", "currency": "EUR", "stock": 5}


async def test_create_then_get_is_served_from_cache(client, repo):
    created = await client.post("/products", json=PRODUCT, headers={"X-Tenant-ID": "acme"})
    assert created.status_code == 201
    product = created.json()
    assert product["price"] == 19.99

    for _ in range(3):
        resp = await client.get(f"/products/{product['id']}", headers={"X-Tenant-ID": "acme"})
        assert resp.status_code == 200
        assert resp.json()["name"] == "Widget"
    assert repo.get_calls == 0  # write-through on create, then cache hits


async def test_tenant_isolation(client):
    created = (await client.post("/products", json=PRODUCT, headers={"X-Tenant-ID": "acme"})).json()
    other = await client.get(f"/products/{created['id']}", headers={"X-Tenant-ID": "globex"})
    assert other.status_code == 404
    assert (await client.get("/products", headers={"X-Tenant-ID": "globex"})).json() == []


async def test_correlation_id_is_echoed_or_generated(client):
    resp = await client.get("/products", headers={"X-Correlation-ID": "abc-123"})
    assert resp.headers["x-correlation-id"] == "abc-123"
    assert (await client.get("/products")).headers["x-correlation-id"]


async def test_validation_error(client):
    resp = await client.post("/products", json={**PRODUCT, "currency": "euro"})
    assert resp.status_code == 422


async def test_database_outage_returns_503_and_opens_breaker(client, repo):
    repo.fail = True
    pid = uuid.uuid4()
    statuses = [(await client.get(f"/products/{pid}")).status_code for _ in range(4)]
    assert statuses == [503, 503, 503, 503]
    # After 3 failures the breaker is open: the 4th call never reached the repository.
    assert repo.get_calls == 3


async def test_cache_outage_degrades_to_database(client, repo, redis):
    created = (await client.post("/products", json=PRODUCT)).json()

    async def broken(*_args, **_kwargs):
        raise ConnectionError("redis down")

    redis.get = broken
    redis.set = broken
    resp = await client.get(f"/products/{created['id']}")
    assert resp.status_code == 200
    assert repo.get_calls == 1


async def test_probes_and_metrics(client, repo):
    assert (await client.get("/health/live")).status_code == 200
    assert (await client.get("/health/startup")).status_code == 200
    ready = await client.get("/health/ready")
    assert ready.status_code == 200
    assert ready.json()["checks"]["postgres"] == "UP"
    repo.fail = True
    assert (await client.get("/health/ready")).status_code == 503
    metrics = await client.get("/metrics")
    assert metrics.status_code == 200
    assert "catalog_cache_requests_total" in metrics.text
