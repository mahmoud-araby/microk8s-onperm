"""Configuration from the standard platform environment variables (docs/conventions.md)."""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore", case_sensitive=False)

    app_name: str = "catalog"
    app_version: str = "dev"
    tenant_id: str = "shared"
    environment: str = "local"
    log_level: str = "INFO"

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "catalog"
    db_user: str = "catalog"
    db_password: str = "catalog"  # noqa: S105 - local dev default; injected from Vault in clusters
    db_pool_size: int = 10
    db_max_overflow: int = 5
    db_timeout_seconds: float = 3.0

    redis_host: str = "localhost"
    redis_port: int = 6379
    redis_password: str | None = None
    redis_db: int = 0
    redis_key_prefix: str = ""
    cache_ttl_seconds: int = 300

    kafka_enabled: bool = False
    kafka_bootstrap_servers: str = "localhost:9092"
    # Platform listeners: SASL SCRAM-SHA-512 (SASL_PLAINTEXT / SASL_SSL); local compose: PLAINTEXT, no credentials.
    kafka_security_protocol: str = "PLAINTEXT"
    kafka_sasl_mechanism: str = "SCRAM-SHA-512"
    kafka_username: str | None = None
    kafka_password: str | None = None
    kafka_ssl_ca_file: str | None = None  # Strimzi cluster CA (PEM) for SASL_SSL / SSL
    # Topics and consumer groups carry the tenant prefix (Kafka ACLs), e.g. "acme.inventory-events".
    kafka_topic_prefix: str = "platform."
    kafka_inventory_topic: str | None = None
    kafka_consumer_group: str | None = None
    kafka_client_id: str | None = None

    otel_exporter_otlp_endpoint: str | None = None
    otel_exporter_otlp_protocol: str = "grpc"
    otel_service_name: str | None = None

    # Bulkhead: max concurrent DB operations per worker (excess requests wait up to the timeout, then 503).
    bulkhead_max_concurrency: int = Field(default=15, ge=1)

    @property
    def database_url(self) -> str:
        return f"postgresql+asyncpg://{self.db_user}:{self.db_password}@{self.db_host}:{self.db_port}/{self.db_name}"

    @property
    def inventory_topic(self) -> str:
        return self.kafka_inventory_topic or f"{self.kafka_topic_prefix}inventory-events"

    @property
    def consumer_group(self) -> str:
        return self.kafka_consumer_group or f"{self.kafka_topic_prefix}{self.app_name}"

    def kafka_client_options(self) -> dict:
        """aiokafka security options derived from the platform KAFKA_* env vars."""
        options: dict = {
            "security_protocol": self.kafka_security_protocol,
            "client_id": self.kafka_client_id or self.app_name,
        }
        if self.kafka_security_protocol.startswith("SASL_"):
            options |= {
                "sasl_mechanism": self.kafka_sasl_mechanism,
                "sasl_plain_username": self.kafka_username,
                "sasl_plain_password": self.kafka_password,
            }
        if self.kafka_security_protocol.endswith("SSL"):
            from aiokafka.helpers import create_ssl_context

            options["ssl_context"] = create_ssl_context(cafile=self.kafka_ssl_ca_file)
        return options

    @property
    def service_name(self) -> str:
        return self.otel_service_name or self.app_name


@lru_cache
def get_settings() -> Settings:
    return Settings()
