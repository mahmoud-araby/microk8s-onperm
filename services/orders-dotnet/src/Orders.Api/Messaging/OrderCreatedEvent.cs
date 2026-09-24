using Orders.Api.Data;

namespace Orders.Api.Messaging;

/// <summary>
/// Integration event contract shared with payments (RabbitMQ queue payments.order-created) and the Kafka order stream.
/// Serialized camelCase.
/// </summary>
public sealed record OrderCreatedEvent(
    Guid EventId,
    string EventType,
    DateTimeOffset OccurredAt,
    string TenantId,
    string CorrelationId,
    Guid OrderId,
    string CustomerId,
    decimal TotalAmount,
    string Currency,
    IReadOnlyList<OrderCreatedEvent.Item> Items)
{
    public sealed record Item(Guid ProductId, int Quantity, decimal UnitPrice);

    public static OrderCreatedEvent From(Order order, string correlationId) => new(
        Guid.NewGuid(),
        "OrderCreated",
        DateTimeOffset.UtcNow,
        order.TenantId,
        correlationId,
        order.Id,
        order.CustomerId,
        order.TotalAmount,
        order.Currency,
        order.Lines.Select(l => new Item(l.ProductId, l.Quantity, l.UnitPrice)).ToList());
}
