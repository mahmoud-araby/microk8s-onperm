using Confluent.Kafka;
using Microsoft.Extensions.Configuration;
using Orders.Api.Infrastructure;

namespace Orders.Api.Tests;

public sealed class PlatformSettingsTests
{
    private static PlatformSettings From(Dictionary<string, string?> values) =>
        PlatformSettings.From(new ConfigurationBuilder().AddInMemoryCollection(values).Build());

    [Fact]
    public void Local_defaults_are_plaintext_with_platform_prefix()
    {
        var settings = From([]);
        var config = new ProducerConfig();
        settings.ApplyKafkaSecurity(config);

        Assert.Equal(SecurityProtocol.Plaintext, config.SecurityProtocol);
        Assert.Null(config.SaslMechanism);
        Assert.Equal("platform.orders-events", settings.KafkaOrdersTopic);
    }

    [Fact]
    public void Platform_listeners_use_scram_and_tenant_prefixed_topics()
    {
        var settings = From(new()
        {
            ["KAFKA_SECURITY_PROTOCOL"] = "SASL_SSL",
            ["KAFKA_SASL_MECHANISM"] = "SCRAM-SHA-512",
            ["KAFKA_USERNAME"] = "acme-orders",
            ["KAFKA_PASSWORD"] = "secret",
            ["KAFKA_TOPIC_PREFIX"] = "acme.",
            ["KAFKA_SSL_CA_FILE"] = "/etc/kafka-ca/ca.crt",
        });
        var config = new ProducerConfig();
        settings.ApplyKafkaSecurity(config);

        Assert.Equal(SecurityProtocol.SaslSsl, config.SecurityProtocol);
        Assert.Equal(SaslMechanism.ScramSha512, config.SaslMechanism);
        Assert.Equal("acme-orders", config.SaslUsername);
        Assert.Equal("/etc/kafka-ca/ca.crt", config.SslCaLocation);
        Assert.Equal("acme.orders-events", settings.KafkaOrdersTopic);
    }
}
