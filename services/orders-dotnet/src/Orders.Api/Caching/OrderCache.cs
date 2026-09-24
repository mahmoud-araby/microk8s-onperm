using System.Text.Json;
using Orders.Api.Data;
using Orders.Api.Infrastructure;
using StackExchange.Redis;
using Order = Orders.Api.Data.Order;

namespace Orders.Api.Caching;

public interface IOrderCache
{
    Task<Order?> GetAsync(string tenant, Guid id);
    Task SetAsync(Order order);

    /// <summary>Order id previously created with this Idempotency-Key, if any.</summary>
    Task<Guid?> GetIdempotentOrderIdAsync(string tenant, string idempotencyKey);
    Task RememberIdempotencyKeyAsync(string tenant, string idempotencyKey, Guid orderId);
}

/// <summary>Cache-aside for single orders. Redis failures degrade to the database, never fail the request.</summary>
public sealed class RedisOrderCache(IConnectionMultiplexer redis, PlatformSettings settings, OrdersMetrics metrics,
    ILogger<RedisOrderCache> logger) : IOrderCache
{
    private static readonly TimeSpan IdempotencyTtl = TimeSpan.FromHours(24);
    private readonly TimeSpan _ttl = TimeSpan.FromSeconds(settings.CacheTtlSeconds);

    private string Key(string tenant, Guid id) => $"{settings.RedisKeyPrefix}{tenant}:order:{id}";

    private string IdempotencyKey(string tenant, string key) => $"{settings.RedisKeyPrefix}{tenant}:idem:{key}";

    public async Task<Order?> GetAsync(string tenant, Guid id)
    {
        try
        {
            var value = await redis.GetDatabase().StringGetAsync(Key(tenant, id));
            metrics.Cache(value.HasValue ? "hit" : "miss");
            return value.HasValue ? JsonSerializer.Deserialize<Order>(value.ToString()) : null;
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            metrics.Cache("error");
            logger.LogDebug(ex, "Redis unavailable, bypassing cache");
            return null;
        }
    }

    public async Task SetAsync(Order order)
    {
        try
        {
            // +/-10% TTL jitter avoids synchronized expiry of hot keys
            var ttl = _ttl * (0.9 + (Random.Shared.NextDouble() * 0.2));
            await redis.GetDatabase().StringSetAsync(Key(order.TenantId, order.Id), JsonSerializer.Serialize(order), ttl);
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            metrics.Cache("error");
            logger.LogDebug(ex, "Redis unavailable, not caching order {OrderId}", order.Id);
        }
    }

    public async Task<Guid?> GetIdempotentOrderIdAsync(string tenant, string idempotencyKey)
    {
        try
        {
            var value = await redis.GetDatabase().StringGetAsync(IdempotencyKey(tenant, idempotencyKey));
            return value.HasValue && Guid.TryParse(value.ToString(), out var id) ? id : null;
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            logger.LogWarning("Redis unavailable, cannot check Idempotency-Key");
            return null;
        }
    }

    public async Task RememberIdempotencyKeyAsync(string tenant, string idempotencyKey, Guid orderId)
    {
        try
        {
            await redis.GetDatabase().StringSetAsync(IdempotencyKey(tenant, idempotencyKey), orderId.ToString(), IdempotencyTtl,
                When.NotExists);
        }
        catch (Exception ex) when (ex is RedisException or TimeoutException)
        {
            logger.LogWarning("Redis unavailable, Idempotency-Key for order {OrderId} not stored", orderId);
        }
    }
}
