"""Product endpoints. Kong strips /catalog/<version>, so routes are unversioned inside a release."""

import uuid
from decimal import Decimal

from fastapi import APIRouter, HTTPException, Query, Request, status
from pydantic import BaseModel, Field

from app.service import ProductService

router = APIRouter(prefix="/products", tags=["products"])


class ProductIn(BaseModel):
    sku: str = Field(min_length=1, max_length=64)
    name: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=2000)
    price: Decimal = Field(gt=0, max_digits=19, decimal_places=4)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    stock: int = Field(default=0, ge=0)


class ProductOut(BaseModel):
    id: uuid.UUID
    sku: str
    name: str
    description: str
    price: float
    currency: str
    stock: int


def _service(request: Request) -> ProductService:
    return request.app.state.service


def _tenant(request: Request) -> str:
    return request.state.tenant_id


@router.get("", response_model=list[ProductOut])
async def list_products(
    request: Request, limit: int = Query(50, ge=1, le=200), offset: int = Query(0, ge=0)
) -> list[dict]:
    return await _service(request).list(_tenant(request), limit, offset)


@router.get("/{product_id}", response_model=ProductOut)
async def get_product(request: Request, product_id: uuid.UUID) -> dict:
    product = await _service(request).get(_tenant(request), product_id)
    if product is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "product not found")
    return product


@router.post("", response_model=ProductOut, status_code=status.HTTP_201_CREATED)
async def create_product(request: Request, body: ProductIn) -> dict:
    return await _service(request).create(_tenant(request), body.model_dump())
