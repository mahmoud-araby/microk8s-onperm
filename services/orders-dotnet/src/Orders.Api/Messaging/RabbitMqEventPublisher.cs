using RabbitMQ.Client;
using Orders.Api.Infrastructure;

namespace Orders.Api.Messaging;

/// <summary>One long-lived, auto-recovering AMQP connection per process; shared with the readiness check.</summary>
public sealed class RabbitMqConnection(PlatformSettings settings) : IAsyncDisposable
{
    private readonly ConnectionFactory _factory = settings.RabbitMqFactory();
    private readonly SemaphoreSlim _lock = new(1, 1);
    private IConnection? _connection;

    public async Task<IConnection> GetAsync(CancellationToken cancellationToken = default)
    {
        if (_connection is not null)
        {
            return _connection; // automatic recovery handles broker restarts
        }

        await _lock.WaitAsync(cancellationToken);
        try
        {
            return _connection ??= await _factory.CreateConnectionAsync(cancellationToken);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_connection is not null)
        {
            await _connection.CloseAsync();
            await _connection.DisposeAsync();
        }

        _lock.Dispose();
    }
}

/// <summary>Publishes with publisher confirms (awaited), persistent messages, to a durable topic exchange.</summary>
public sealed class RabbitMqEventPublisher(RabbitMqConnection connection, PlatformSettings settings) : IAsyncDisposable
{
    private readonly SemaphoreSlim _lock = new(1, 1);
    private IChannel? _channel;

    public async Task PublishAsync(ReadOnlyMemory<byte> body, BasicProperties properties, CancellationToken cancellationToken)
    {
        await _lock.WaitAsync(cancellationToken);
        try
        {
            if (_channel is not { IsOpen: true })
            {
                var conn = await connection.GetAsync(cancellationToken);
                _channel = await conn.CreateChannelAsync(
                    new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true),
                    cancellationToken);
                await _channel.ExchangeDeclareAsync(settings.RabbitMqExchange, ExchangeType.Topic, durable: true, autoDelete: false,
                    cancellationToken: cancellationToken);
            }

            await _channel.BasicPublishAsync(settings.RabbitMqExchange, settings.RabbitMqRoutingKey, mandatory: false, properties, body,
                cancellationToken);
        }
        finally
        {
            _lock.Release();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_channel is not null)
        {
            await _channel.CloseAsync();
            await _channel.DisposeAsync();
        }

        _lock.Dispose();
    }
}
