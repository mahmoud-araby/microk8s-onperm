using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Orders.Api.Infrastructure;
using RabbitMQ.Client;

namespace Orders.Api.Messaging;

public interface IOrderEventsPublisher
{
    Task PublishOrderCreatedAsync(OrderCreatedEvent evt);
}

/// <summary>
/// Fans an OrderCreated event out to RabbitMQ (work queue for payments) and Kafka (event stream), propagating
/// tenant, correlation id and W3C trace context as message headers.
/// Publishing happens after the DB commit; a failure is logged and counted, never failing the request. For
/// guaranteed delivery evolve this into a transactional outbox.
/// </summary>
public sealed class OrderEventsPublisher(
    RabbitMqEventPublisher rabbit,
    KafkaEventPublisher kafka,
    PlatformSettings settings,
    OrdersMetrics metrics,
    ILogger<OrderEventsPublisher> logger) : IOrderEventsPublisher
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly TimeSpan PublishTimeout = TimeSpan.FromSeconds(3);

    public async Task PublishOrderCreatedAsync(OrderCreatedEvent evt)
    {
        using var activity = OrdersMetrics.ActivitySource.StartActivity("orders.events publish", ActivityKind.Producer);
        activity?.SetTag("messaging.message.id", evt.EventId.ToString());

        var headers = new Dictionary<string, string>
        {
            ["x-tenant-id"] = evt.TenantId,
            ["x-correlation-id"] = evt.CorrelationId,
            ["event-type"] = evt.EventType,
        };
        DistributedContextPropagator.Current.Inject(activity ?? Activity.Current, headers,
            static (carrier, key, value) => ((Dictionary<string, string>)carrier!)[key] = value);

        var payload = JsonSerializer.Serialize(evt, Json);
        using var cts = new CancellationTokenSource(PublishTimeout);

        await Task.WhenAll(
            Guard("rabbitmq", () => rabbit.PublishAsync(Encoding.UTF8.GetBytes(payload),
                new BasicProperties
                {
                    ContentType = "application/json",
                    DeliveryMode = DeliveryModes.Persistent,
                    MessageId = evt.EventId.ToString(),
                    CorrelationId = evt.CorrelationId,
                    Type = evt.EventType,
                    AppId = settings.AppName,
                    Headers = headers.ToDictionary(h => h.Key, h => (object?)h.Value),
                }, cts.Token)),
            Guard("kafka", () => kafka.PublishAsync(settings.KafkaOrdersTopic, evt.OrderId.ToString(), payload, headers, cts.Token)));
    }

    private async Task Guard(string broker, Func<Task> publish)
    {
        try
        {
            await publish();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            metrics.PublishFailed(broker);
            logger.LogError(ex, "Failed to publish OrderCreated to {Broker}", broker);
        }
    }
}
