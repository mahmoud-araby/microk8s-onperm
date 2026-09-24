using Asp.Versioning;
using Asp.Versioning.Builder;
using Microsoft.AspNetCore.Http.HttpResults;
using Orders.Api.Data;
using Orders.Api.Infrastructure;

namespace Orders.Api.Endpoints;

/// <summary>
/// Same routes, two API versions. Kong strips /orders/{v1|v2}; the version is selected by the X-API-Version header,
/// or defaults to API_DEFAULT_VERSION of the release (orders-v1 → 1.0, orders-v2 → 2.0).
/// </summary>
public static class OrdersApi
{
    public const string WritePolicy = "orders-write";

    // ---- v1 contract ----
    public sealed record OrderLineV1(Guid ProductId, string ProductName, int Quantity, decimal UnitPrice);

    public sealed record OrderV1(Guid Id, string CustomerId, string Status, string Currency, decimal Total,
        DateTimeOffset CreatedAt, IReadOnlyList<OrderLineV1> Items)
    {
        public static OrderV1 From(Order o) => new(o.Id, o.CustomerId, o.Status, o.Currency, o.TotalAmount, o.CreatedAt,
            o.Lines.Select(l => new OrderLineV1(l.ProductId, l.ProductName, l.Quantity, l.UnitPrice)).ToList());
    }

    // ---- v2 contract: money as an object, customer as a reference, paging envelope, links ----
    public sealed record Money(decimal Value, string Currency);

    public sealed record CustomerRef(string Id);

    public sealed record OrderLineV2(Guid ProductId, string Name, int Quantity, Money UnitPrice);

    public sealed record OrderV2(Guid Id, CustomerRef Customer, string Status, Money Amount, DateTimeOffset CreatedAt,
        IReadOnlyList<OrderLineV2> Lines, IReadOnlyDictionary<string, string> Links)
    {
        public static OrderV2 From(Order o) => new(o.Id, new CustomerRef(o.CustomerId), o.Status.ToUpperInvariant(),
            new Money(o.TotalAmount, o.Currency), o.CreatedAt,
            o.Lines.Select(l => new OrderLineV2(l.ProductId, l.ProductName, l.Quantity, new Money(l.UnitPrice, o.Currency))).ToList(),
            new Dictionary<string, string> { ["self"] = $"orders/{o.Id}" });
    }

    public sealed record PagedResult<T>(IReadOnlyList<T> Items, int Page, int PageSize, int Total);

    public static void MapOrdersApi(this IEndpointRouteBuilder app)
    {
        IVersionedEndpointRouteBuilder api = app.NewVersionedApi("Orders");

        var v1 = api.MapGroup("/orders").HasApiVersion(new ApiVersion(1, 0));
        v1.MapPost("/", CreateV1).RequireRateLimiting(WritePolicy);
        v1.MapGet("/{id:guid}", GetV1);
        v1.MapGet("/", ListV1);

        var v2 = api.MapGroup("/orders").HasApiVersion(new ApiVersion(2, 0));
        v2.MapPost("/", CreateV2).RequireRateLimiting(WritePolicy);
        v2.MapGet("/{id:guid}", GetV2);
        v2.MapGet("/", ListV2);
    }

    private static string? IdempotencyKey(HttpContext http) =>
        http.Request.Headers["Idempotency-Key"].FirstOrDefault() is { Length: > 0 and <= 128 } key ? key : null;

    private static async Task<Results<Created<OrderV1>, ValidationProblem>> CreateV1(
        CreateOrderRequest request, OrderService service, HttpContext http, CancellationToken ct)
    {
        var result = await service.CreateAsync(http.GetTenantId(), http.GetCorrelationId(), IdempotencyKey(http), request, ct);
        return result.Order is null
            ? TypedResults.ValidationProblem(result.Errors!)
            : TypedResults.Created($"orders/{result.Order.Id}", OrderV1.From(result.Order));
    }

    private static async Task<Results<Ok<OrderV1>, NotFound>> GetV1(Guid id, OrderService service, HttpContext http,
        CancellationToken ct) =>
        await service.GetAsync(http.GetTenantId(), id, ct) is { } order
            ? TypedResults.Ok(OrderV1.From(order))
            : TypedResults.NotFound();

    private static async Task<Ok<List<OrderV1>>> ListV1(OrderService service, HttpContext http, CancellationToken ct,
        int page = 1, int pageSize = 50)
    {
        var (items, _) = await service.ListAsync(http.GetTenantId(), Math.Max(page, 1), Math.Clamp(pageSize, 1, 200), ct);
        return TypedResults.Ok(items.Select(OrderV1.From).ToList());
    }

    private static async Task<Results<Created<OrderV2>, ValidationProblem>> CreateV2(
        CreateOrderRequest request, OrderService service, HttpContext http, CancellationToken ct)
    {
        var result = await service.CreateAsync(http.GetTenantId(), http.GetCorrelationId(), IdempotencyKey(http), request, ct);
        return result.Order is null
            ? TypedResults.ValidationProblem(result.Errors!)
            : TypedResults.Created($"orders/{result.Order.Id}", OrderV2.From(result.Order));
    }

    private static async Task<Results<Ok<OrderV2>, NotFound>> GetV2(Guid id, OrderService service, HttpContext http,
        CancellationToken ct) =>
        await service.GetAsync(http.GetTenantId(), id, ct) is { } order
            ? TypedResults.Ok(OrderV2.From(order))
            : TypedResults.NotFound();

    private static async Task<Ok<PagedResult<OrderV2>>> ListV2(OrderService service, HttpContext http, CancellationToken ct,
        int page = 1, int pageSize = 50)
    {
        page = Math.Max(page, 1);
        pageSize = Math.Clamp(pageSize, 1, 200);
        var (items, total) = await service.ListAsync(http.GetTenantId(), page, pageSize, ct);
        return TypedResults.Ok(new PagedResult<OrderV2>(items.Select(OrderV2.From).ToList(), page, pageSize, total));
    }
}
