using System.Net;

namespace Orders.Api.Catalog;

public sealed record CatalogProduct(Guid Id, string Sku, string Name, decimal Price, string Currency, int Stock);

public interface ICatalogClient
{
    Task<CatalogProduct?> GetProductAsync(Guid productId, CancellationToken cancellationToken);
}

/// <summary>
/// Typed client for the catalog service (in-mesh: http://catalog-v1). Resilience (retry with jitter, attempt/total
/// timeouts, circuit breaker, concurrency limiter = bulkhead) comes from the standard resilience handler in Program.cs.
/// </summary>
public sealed class CatalogClient(HttpClient http) : ICatalogClient
{
    public async Task<CatalogProduct?> GetProductAsync(Guid productId, CancellationToken cancellationToken)
    {
        using var response = await http.GetAsync(new Uri($"products/{productId}", UriKind.Relative), cancellationToken);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<CatalogProduct>(cancellationToken);
    }
}

/// <summary>Propagates X-Tenant-ID and X-Correlation-ID to downstream calls (traceparent is added by .NET itself).</summary>
public sealed class PlatformHeadersHandler(IHttpContextAccessor accessor) : DelegatingHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (accessor.HttpContext is { } context)
        {
            foreach (var header in new[] { Infrastructure.RequestContext.TenantHeader, Infrastructure.RequestContext.CorrelationHeader })
            {
                if (context.Request.Headers.TryGetValue(header, out var value))
                {
                    request.Headers.TryAddWithoutValidation(header, (IEnumerable<string>)value!);
                }
            }
        }

        return base.SendAsync(request, cancellationToken);
    }
}
