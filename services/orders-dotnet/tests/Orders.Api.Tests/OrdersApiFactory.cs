using System.Collections.Concurrent;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Orders.Api.Caching;
using Orders.Api.Catalog;
using Orders.Api.Data;
using Orders.Api.Messaging;

namespace Orders.Api.Tests;

/// <summary>Runs the real pipeline (middleware, versioning, handlers) with in-memory infrastructure.</summary>
public sealed class OrdersApiFactory : WebApplicationFactory<Program>
{
    private readonly string _database = Guid.NewGuid().ToString();

    public FakeCatalog Catalog { get; } = new();

    public FakePublisher Publisher { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureTestServices(services =>
        {
            services.RemoveAll<DbContextOptions<OrdersDbContext>>();
            services.AddDbContext<OrdersDbContext>(o => o.UseInMemoryDatabase(_database));
            services.RemoveAll<ICatalogClient>();
            services.AddSingleton<ICatalogClient>(Catalog);
            services.RemoveAll<IOrderCache>();
            services.AddSingleton<IOrderCache, InMemoryOrderCache>();
            services.RemoveAll<IOrderEventsPublisher>();
            services.AddSingleton<IOrderEventsPublisher>(Publisher);
        });
    }
}

public sealed class FakeCatalog : ICatalogClient
{
    public ConcurrentDictionary<Guid, CatalogProduct> Products { get; } = new();

    public Exception? Failure { get; set; }

    public Task<CatalogProduct?> GetProductAsync(Guid productId, CancellationToken cancellationToken) =>
        Failure is not null
            ? Task.FromException<CatalogProduct?>(Failure)
            : Task.FromResult(Products.TryGetValue(productId, out var p) ? p : null);

    public CatalogProduct Add(string name, decimal price, string currency = "EUR")
    {
        var product = new CatalogProduct(Guid.NewGuid(), name.ToUpperInvariant(), name, price, currency, 100);
        Products[product.Id] = product;
        return product;
    }
}

public sealed class FakePublisher : IOrderEventsPublisher
{
    public ConcurrentQueue<OrderCreatedEvent> Published { get; } = new();

    public Task PublishOrderCreatedAsync(OrderCreatedEvent evt)
    {
        Published.Enqueue(evt);
        return Task.CompletedTask;
    }
}

public sealed class InMemoryOrderCache : IOrderCache
{
    private readonly ConcurrentDictionary<(string, Guid), Order> _orders = new();
    private readonly ConcurrentDictionary<(string, string), Guid> _idempotency = new();

    public Task<Guid?> GetIdempotentOrderIdAsync(string tenant, string idempotencyKey) =>
        Task.FromResult(_idempotency.TryGetValue((tenant, idempotencyKey), out var id) ? id : (Guid?)null);

    public Task RememberIdempotencyKeyAsync(string tenant, string idempotencyKey, Guid orderId)
    {
        _idempotency.TryAdd((tenant, idempotencyKey), orderId);
        return Task.CompletedTask;
    }

    public Task<Order?> GetAsync(string tenant, Guid id) =>
        Task.FromResult(_orders.TryGetValue((tenant, id), out var o) ? o : null);

    public Task SetAsync(Order order)
    {
        _orders[(order.TenantId, order.Id)] = order;
        return Task.CompletedTask;
    }
}
