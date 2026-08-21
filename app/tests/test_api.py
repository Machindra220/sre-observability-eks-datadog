import pytest
from httpx import AsyncClient, ASGITransport
from src.main import app


@pytest.mark.asyncio
async def test_health():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/health")
    assert r.status_code == 200
    assert r.json()["status"] == "healthy"


@pytest.mark.asyncio
async def test_ready():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/ready")
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_products():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/products")
    assert r.status_code == 200
    assert len(r.json()["products"]) == 3


@pytest.mark.asyncio
async def test_orders():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/orders")
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_users():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/users")
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_error_returns_error_status():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r = await client.get("/api/error")
    assert r.status_code in (400, 500)