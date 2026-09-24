"""Pure ASGI middleware: tenant + correlation id → log context, span attributes and response header."""

import uuid

import structlog
from opentelemetry import trace
from starlette.types import ASGIApp, Message, Receive, Scope, Send

TENANT_HEADER = b"x-tenant-id"
CORRELATION_HEADER = b"x-correlation-id"


class RequestContextMiddleware:
    def __init__(self, app: ASGIApp, default_tenant: str) -> None:
        self.app = app
        self.default_tenant = default_tenant

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope["headers"])
        tenant = headers.get(TENANT_HEADER, b"").decode() or self.default_tenant
        correlation_id = headers.get(CORRELATION_HEADER, b"").decode() or str(uuid.uuid4())
        scope.setdefault("state", {})["tenant_id"] = tenant

        span = trace.get_current_span()
        span.set_attribute("tenant.id", tenant)
        span.set_attribute("correlation.id", correlation_id)

        async def send_with_header(message: Message) -> None:
            if message["type"] == "http.response.start":
                message.setdefault("headers", []).append((CORRELATION_HEADER, correlation_id.encode()))
            await send(message)

        with structlog.contextvars.bound_contextvars(tenant_id=tenant, correlation_id=correlation_id):
            await self.app(scope, receive, send_with_header)
