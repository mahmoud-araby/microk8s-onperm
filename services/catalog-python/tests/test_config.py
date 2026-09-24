from app.config import Settings


def test_local_kafka_defaults_are_plaintext():
    settings = Settings()
    assert settings.kafka_client_options() == {"security_protocol": "PLAINTEXT", "client_id": "catalog"}
    assert settings.inventory_topic == "platform.inventory-events"
    assert settings.consumer_group == "platform.catalog"


def test_platform_kafka_uses_scram_and_tenant_prefix(monkeypatch):
    for key, value in {
        "KAFKA_SECURITY_PROTOCOL": "SASL_PLAINTEXT",
        "KAFKA_SASL_MECHANISM": "SCRAM-SHA-512",
        "KAFKA_USERNAME": "acme-catalog",
        "KAFKA_PASSWORD": "s3cr3t",
        "KAFKA_TOPIC_PREFIX": "acme.",
        "KAFKA_CONSUMER_GROUP": "acme.catalog-v1",
    }.items():
        monkeypatch.setenv(key, value)
    settings = Settings()

    options = settings.kafka_client_options()
    assert options["sasl_mechanism"] == "SCRAM-SHA-512"
    assert options["sasl_plain_username"] == "acme-catalog"
    assert "ssl_context" not in options
    assert settings.inventory_topic == "acme.inventory-events"
    assert settings.consumer_group == "acme.catalog-v1"
