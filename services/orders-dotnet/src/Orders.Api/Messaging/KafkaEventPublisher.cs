using System.Text;
using Confluent.Kafka;
using Orders.Api.Infrastructure;

namespace Orders.Api.Messaging;

/// <summary>Idempotent Kafka producer (acks=all, enable.idempotence) — no duplicates on producer retries.</summary>
public sealed class KafkaEventPublisher : IDisposable
{
    private readonly IProducer<string, string> _producer;

    public KafkaEventPublisher(PlatformSettings settings, ILogger<KafkaEventPublisher> logger)
    {
        var config = new ProducerConfig
        {
            BootstrapServers = settings.KafkaBootstrapServers,
            ClientId = settings.KafkaClientId,
            EnableIdempotence = true,
            Acks = Acks.All,
            LingerMs = 5,
            CompressionType = CompressionType.Lz4,
            MessageTimeoutMs = 10_000,
            SocketConnectionSetupTimeoutMs = 5_000,
        };
        settings.ApplyKafkaSecurity(config);
        _producer = new ProducerBuilder<string, string>(config)
            .SetErrorHandler((_, e) => logger.LogWarning("Kafka producer error {Code}: {Reason}", e.Code, e.Reason))
            .Build();
    }

    public async Task PublishAsync(string topic, string key, string payload, IReadOnlyDictionary<string, string> headers,
        CancellationToken cancellationToken)
    {
        var kafkaHeaders = new Headers();
        foreach (var (name, value) in headers)
        {
            kafkaHeaders.Add(name, Encoding.UTF8.GetBytes(value));
        }

        await _producer.ProduceAsync(topic, new Message<string, string> { Key = key, Value = payload, Headers = kafkaHeaders },
            cancellationToken);
    }

    public void Dispose()
    {
        // Graceful shutdown: deliver in-flight messages before the process exits.
        _producer.Flush(TimeSpan.FromSeconds(10));
        _producer.Dispose();
    }
}
