using System.Net;
using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Orders.Api.Catalog;

namespace Orders.Api.Tests;

/// <summary>Verifies the real resilience pipeline registration (same config section as appsettings.json).</summary>
public sealed class CatalogResilienceTests
{
    private sealed class FlakyHandler(int failures) : HttpMessageHandler
    {
        public int Calls { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            if (Calls <= failures)
            {
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
            }

            var json = $$"""{"id":"{{Guid.Empty}}","sku":"S","name":"Widget","price":9.5,"currency":"EUR","stock":1}""";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json"),
            });
        }
    }

    private static (ICatalogClient Client, FlakyHandler Handler) Build(int failures)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["CATALOG_BASE_URL"] = "http://catalog-v1/",
            ["Resilience:Catalog:Retry:MaxRetryAttempts"] = "2",
            ["Resilience:Catalog:Retry:Delay"] = "00:00:00.010",
        }).Build();
        var handler = new FlakyHandler(failures);
        var services = new ServiceCollection();
        services.AddCatalogClient(configuration).ConfigurePrimaryHttpMessageHandler(() => handler);
        return (services.BuildServiceProvider().GetRequiredService<ICatalogClient>(), handler);
    }

    [Fact]
    public async Task Transient_failures_are_retried_with_backoff()
    {
        var (client, handler) = Build(failures: 2);

        var product = await client.GetProductAsync(Guid.Empty, CancellationToken.None);

        Assert.Equal("Widget", product!.Name);
        Assert.Equal(3, handler.Calls);
    }

    [Fact]
    public async Task Retries_are_bounded()
    {
        var (client, handler) = Build(failures: 10);

        await Assert.ThrowsAsync<HttpRequestException>(() => client.GetProductAsync(Guid.Empty, CancellationToken.None));
        Assert.Equal(3, handler.Calls);
    }
}
