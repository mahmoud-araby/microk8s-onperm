using Microsoft.Extensions.Http.Resilience;

namespace Orders.Api.Catalog;

public static class CatalogClientRegistration
{
    /// <summary>
    /// HttpClientFactory + standard resilience pipeline: rate limiter (bulkhead) → total timeout → retry
    /// (exponential + jitter) → circuit breaker → attempt timeout. Tuned from configuration "Resilience:Catalog".
    /// Istio also retries at the mesh level, so app-level retries are kept low to avoid retry amplification.
    /// </summary>
    public static IHttpClientBuilder AddCatalogClient(this IServiceCollection services, IConfiguration configuration)
    {
        services.AddHttpContextAccessor();
        services.AddTransient<PlatformHeadersHandler>();
        var builder = services.AddHttpClient<ICatalogClient, CatalogClient>(c =>
                c.BaseAddress = new Uri(configuration["CATALOG_BASE_URL"] ?? "http://catalog-v1/"))
            .AddHttpMessageHandler<PlatformHeadersHandler>();
        builder.AddStandardResilienceHandler(o => configuration.GetSection("Resilience:Catalog").Bind(o));
        return builder;
    }
}
