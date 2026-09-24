using Microsoft.EntityFrameworkCore;
using Orders.Api.Caching;
using Orders.Api.Catalog;
using Orders.Api.Data;
using Orders.Api.Infrastructure;
using Orders.Api.Messaging;

namespace Orders.Api.Endpoints;

public sealed record CreateOrderRequest(string CustomerId, string Currency, IReadOnlyList<CreateOrderLine> Items);

public sealed record CreateOrderLine(Guid ProductId, int Quantity);

public sealed record CreateOrderResult(Order? Order, Dictionary<string, string[]>? Errors);

/// <summary>Version-agnostic use cases; v1 and v2 endpoints only differ in their contracts.</summary>
public sealed class OrderService(
    OrdersDbContext db,
    ICatalogClient catalog,
    IOrderCache cache,
    IOrderEventsPublisher publisher,
    OrdersMetrics metrics)
{
    /// <summary>
    /// Creates an order. With an Idempotency-Key, a retried request (client, Kong or mesh retry) returns the order
    /// created by the first attempt instead of creating a duplicate.
    /// </summary>
    public async Task<CreateOrderResult> CreateAsync(string tenant, string correlationId, string? idempotencyKey,
        CreateOrderRequest request, CancellationToken cancellationToken)
    {
        if (idempotencyKey is not null
            && await cache.GetIdempotentOrderIdAsync(tenant, idempotencyKey) is { } existingId
            && await GetAsync(tenant, existingId, cancellationToken) is { } existing)
        {
            return new CreateOrderResult(existing, null);
        }

        var errors = Validate(request);
        if (errors.Count > 0)
        {
            return new CreateOrderResult(null, errors);
        }

        // Price every distinct product in parallel through the resilient catalog client.
        var lines = request.Items.GroupBy(i => i.ProductId)
            .Select(g => new CreateOrderLine(g.Key, g.Sum(i => i.Quantity)))
            .ToList();
        var products = await Task.WhenAll(lines.Select(l => catalog.GetProductAsync(l.ProductId, cancellationToken)));

        var unknown = lines.Where((_, i) => products[i] is null).Select(l => l.ProductId.ToString()).ToArray();
        if (unknown.Length > 0)
        {
            return new CreateOrderResult(null, new() { ["items"] = [$"Unknown products: {string.Join(", ", unknown)}"] });
        }

        if (products.Any(p => !string.Equals(p!.Currency, request.Currency, StringComparison.Ordinal)))
        {
            return new CreateOrderResult(null, new() { ["currency"] = ["Currency does not match catalog prices"] });
        }

        var order = new Order
        {
            TenantId = tenant,
            CustomerId = request.CustomerId,
            Currency = request.Currency,
            TotalAmount = lines.Select((l, i) => l.Quantity * products[i]!.Price).Sum(),
            Lines = lines.Select((l, i) => new OrderLine
            {
                ProductId = l.ProductId,
                ProductName = products[i]!.Name,
                Quantity = l.Quantity,
                UnitPrice = products[i]!.Price,
            }).ToList(),
        };

        db.Orders.Add(order);
        await db.SaveChangesAsync(cancellationToken);
        metrics.OrderCreated(tenant);

        await cache.SetAsync(order);
        if (idempotencyKey is not null)
        {
            await cache.RememberIdempotencyKeyAsync(tenant, idempotencyKey, order.Id);
        }

        await publisher.PublishOrderCreatedAsync(OrderCreatedEvent.From(order, correlationId));
        return new CreateOrderResult(order, null);
    }

    public async Task<Order?> GetAsync(string tenant, Guid id, CancellationToken cancellationToken)
    {
        var cached = await cache.GetAsync(tenant, id);
        if (cached is not null)
        {
            return cached;
        }

        var order = await db.Orders.AsNoTracking().Include(o => o.Lines)
            .FirstOrDefaultAsync(o => o.TenantId == tenant && o.Id == id, cancellationToken);
        if (order is not null)
        {
            await cache.SetAsync(order);
        }

        return order;
    }

    public async Task<(IReadOnlyList<Order> Items, int Total)> ListAsync(string tenant, int page, int pageSize,
        CancellationToken cancellationToken)
    {
        var query = db.Orders.AsNoTracking().Where(o => o.TenantId == tenant);
        var total = await query.CountAsync(cancellationToken);
        var items = await query.Include(o => o.Lines)
            .OrderByDescending(o => o.CreatedAt)
            .Skip((page - 1) * pageSize)
            .Take(pageSize)
            .ToListAsync(cancellationToken);
        return (items, total);
    }

    private static Dictionary<string, string[]> Validate(CreateOrderRequest request)
    {
        var errors = new Dictionary<string, string[]>();
        if (string.IsNullOrWhiteSpace(request.CustomerId))
        {
            errors["customerId"] = ["customerId is required"];
        }

        if (request.Currency is not { Length: 3 } || !request.Currency.All(char.IsAsciiLetterUpper))
        {
            errors["currency"] = ["currency must be an ISO-4217 code, e.g. EUR"];
        }

        if (request.Items is not { Count: > 0 } || request.Items.Any(i => i.Quantity is < 1 or > 1000))
        {
            errors["items"] = ["at least one item with quantity 1..1000 is required"];
        }

        return errors;
    }
}
