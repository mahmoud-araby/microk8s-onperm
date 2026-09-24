using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Polly.CircuitBreaker;

namespace Orders.Api.Tests;

public sealed class OrdersApiTests : IDisposable
{
    private readonly OrdersApiFactory _factory = new();

    public void Dispose() => _factory.Dispose();

    private HttpClient Client(string tenant = "acme", string? apiVersion = null)
    {
        var client = _factory.CreateClient();
        client.DefaultRequestHeaders.Add("X-Tenant-ID", tenant);
        client.DefaultRequestHeaders.Add("X-Correlation-ID", "corr-123");
        if (apiVersion is not null)
        {
            client.DefaultRequestHeaders.Add("X-API-Version", apiVersion);
        }

        return client;
    }

    [Fact]
    public async Task Create_order_prices_items_from_catalog_and_publishes_event()
    {
        var widget = _factory.Catalog.Add("Widget", 12.50m);
        var gadget = _factory.Catalog.Add("Gadget", 3m);

        var response = await Client().PostAsJsonAsync("/orders", new
        {
            customerId = "cust-1",
            currency = "EUR",
            items = new[] { new { productId = widget.Id, quantity = 2 }, new { productId = gadget.Id, quantity = 1 } },
        });

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Equal("corr-123", response.Headers.GetValues("X-Correlation-ID").Single());
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(28.00m, body.GetProperty("total").GetDecimal());

        var evt = Assert.Single(_factory.Publisher.Published);
        Assert.Equal("acme", evt.TenantId);
        Assert.Equal("corr-123", evt.CorrelationId);
        Assert.Equal(28.00m, evt.TotalAmount);
    }

    [Fact]
    public async Task Orders_are_tenant_scoped()
    {
        var product = _factory.Catalog.Add("Widget", 1m);
        var created = await Client("acme").PostAsJsonAsync("/orders",
            new { customerId = "c", currency = "EUR", items = new[] { new { productId = product.Id, quantity = 1 } } });
        var id = (await created.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetGuid();

        Assert.Equal(HttpStatusCode.OK, (await Client("acme").GetAsync($"/orders/{id}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await Client("globex").GetAsync($"/orders/{id}")).StatusCode);
    }

    [Fact]
    public async Task V2_is_selected_by_header_and_returns_v2_contract()
    {
        var product = _factory.Catalog.Add("Widget", 5m);
        var response = await Client(apiVersion: "2.0").PostAsJsonAsync("/orders",
            new { customerId = "c", currency = "EUR", items = new[] { new { productId = product.Id, quantity = 3 } } });

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(15m, body.GetProperty("amount").GetProperty("value").GetDecimal());
        Assert.Equal("c", body.GetProperty("customer").GetProperty("id").GetString());

        var page = await Client(apiVersion: "2.0").GetFromJsonAsync<JsonElement>("/orders");
        Assert.Equal(1, page.GetProperty("total").GetInt32());
        Assert.Contains("2.0", response.Headers.GetValues("api-supported-versions").Single(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task Unknown_product_is_a_validation_error()
    {
        var response = await Client().PostAsJsonAsync("/orders",
            new { customerId = "c", currency = "EUR", items = new[] { new { productId = Guid.NewGuid(), quantity = 1 } } });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(_factory.Publisher.Published);
    }

    [Fact]
    public async Task Open_catalog_circuit_returns_503()
    {
        var product = _factory.Catalog.Add("Widget", 5m);
        _factory.Catalog.Failure = new BrokenCircuitException("catalog circuit open");

        var response = await Client().PostAsJsonAsync("/orders",
            new { customerId = "c", currency = "EUR", items = new[] { new { productId = product.Id, quantity = 1 } } });

        Assert.Equal(HttpStatusCode.ServiceUnavailable, response.StatusCode);
        Assert.True(response.Headers.Contains("Retry-After"));
    }

    [Fact]
    public async Task Retried_post_with_same_idempotency_key_does_not_duplicate_the_order()
    {
        var product = _factory.Catalog.Add("Widget", 5m);
        var client = Client();
        client.DefaultRequestHeaders.Add("Idempotency-Key", "key-1");
        var body = new { customerId = "c", currency = "EUR", items = new[] { new { productId = product.Id, quantity = 1 } } };

        var first = await (await client.PostAsJsonAsync("/orders", body)).Content.ReadFromJsonAsync<JsonElement>();
        var second = await (await client.PostAsJsonAsync("/orders", body)).Content.ReadFromJsonAsync<JsonElement>();

        Assert.Equal(first.GetProperty("id").GetGuid(), second.GetProperty("id").GetGuid());
        Assert.Single(_factory.Publisher.Published);
    }

    [Fact]
    public async Task Liveness_and_startup_probes_are_up()
    {
        var client = _factory.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/live")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/startup")).StatusCode);
        var metrics = await client.GetStringAsync("/metrics");
        Assert.Contains("http_request_duration_seconds", metrics, StringComparison.Ordinal);
    }
}
