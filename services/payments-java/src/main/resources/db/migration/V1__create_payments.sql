CREATE TABLE payments (
    id                 UUID PRIMARY KEY,
    tenant_id          VARCHAR(64)    NOT NULL,
    order_id           UUID           NOT NULL,
    amount             NUMERIC(19, 4) NOT NULL CHECK (amount > 0),
    currency           VARCHAR(3)     NOT NULL,
    status             VARCHAR(16)    NOT NULL,
    provider_reference VARCHAR(128),
    failure_reason     VARCHAR(1024),
    created_at         TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ    NOT NULL DEFAULT now(),
    version            BIGINT         NOT NULL DEFAULT 0,
    CONSTRAINT uq_payments_tenant_order UNIQUE (tenant_id, order_id)
);

CREATE INDEX ix_payments_tenant_created ON payments (tenant_id, created_at DESC);
