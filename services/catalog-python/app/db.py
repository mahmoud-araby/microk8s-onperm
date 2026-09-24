"""Async SQLAlchemy engine, ORM model and repository."""

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import DateTime, Integer, Numeric, String, UniqueConstraint, select, text, update
from sqlalchemy.ext.asyncio import AsyncEngine, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from app.config import Settings
from app.resilience import db_retry


class Base(DeclarativeBase):
    pass


class Product(Base):
    __tablename__ = "products"
    __table_args__ = (UniqueConstraint("tenant_id", "sku", name="uq_products_tenant_sku"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    tenant_id: Mapped[str] = mapped_column(String(64), index=True)
    sku: Mapped[str] = mapped_column(String(64))
    name: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(String(2000), default="")
    price: Mapped[Decimal] = mapped_column(Numeric(19, 4))
    currency: Mapped[str] = mapped_column(String(3))
    stock: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(UTC))

    def to_dict(self) -> dict:
        return {
            "id": str(self.id),
            "sku": self.sku,
            "name": self.name,
            "description": self.description,
            "price": float(self.price),
            "currency": self.currency,
            "stock": self.stock,
        }


def create_engine(settings: Settings) -> AsyncEngine:
    return create_async_engine(
        settings.database_url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_pre_ping=True,
        pool_recycle=1800,
        pool_timeout=settings.db_timeout_seconds,
        connect_args={
            # PgBouncer (transaction pooling) compatible: no server-side prepared statement cache.
            "statement_cache_size": 0,
            "prepared_statement_cache_size": 0,
            "command_timeout": settings.db_timeout_seconds,
            "timeout": settings.db_timeout_seconds,
            "server_settings": {"application_name": settings.app_name},
        },
    )


class ProductRepository:
    """All queries are tenant scoped."""

    def __init__(self, engine: AsyncEngine) -> None:
        self._engine = engine
        self._sessions = async_sessionmaker(engine, expire_on_commit=False)

    @db_retry
    async def get(self, tenant: str, product_id: uuid.UUID) -> dict | None:
        async with self._sessions() as s:
            row = await s.scalar(select(Product).where(Product.tenant_id == tenant, Product.id == product_id))
            return row.to_dict() if row else None

    @db_retry
    async def list(self, tenant: str, limit: int, offset: int) -> list[dict]:
        async with self._sessions() as s:
            rows = await s.scalars(
                select(Product).where(Product.tenant_id == tenant).order_by(Product.name).limit(limit).offset(offset)
            )
            return [r.to_dict() for r in rows]

    async def create(self, tenant: str, data: dict) -> dict:
        async with self._sessions.begin() as s:
            product = Product(tenant_id=tenant, **data)
            s.add(product)
        return product.to_dict()

    async def adjust_stock(self, tenant: str, product_id: uuid.UUID, delta: int) -> None:
        async with self._sessions.begin() as s:
            await s.execute(
                update(Product)
                .where(Product.tenant_id == tenant, Product.id == product_id)
                .values(stock=Product.stock + delta)
            )

    async def ping(self) -> None:
        async with self._engine.connect() as conn:
            await conn.execute(text("SELECT 1"))


async def create_schema(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
