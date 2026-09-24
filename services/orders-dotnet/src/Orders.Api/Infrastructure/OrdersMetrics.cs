using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Orders.Api.Infrastructure;

/// <summary>
/// Business metrics via System.Diagnostics.Metrics: exported by OTLP (OpenTelemetry) and on /metrics (prometheus-net's
/// meter adapter).
/// </summary>
public sealed class OrdersMetrics
{
    public const string MeterName = "Orders.Api";
    public static readonly ActivitySource ActivitySource = new("Orders.Api");

    // A process-wide (unscoped) Meter: prometheus-net's meter adapter only bridges unscoped meters.
    private static readonly Meter Meter = new(MeterName);

    private readonly Counter<long> _ordersCreated;
    private readonly Counter<long> _publishFailures;
    private readonly Counter<long> _cacheRequests;

    public OrdersMetrics()
    {
        _ordersCreated = Meter.CreateCounter<long>("orders.created", description: "Orders created");
        _publishFailures = Meter.CreateCounter<long>("orders.events.publish_failures", description: "Event publish failures");
        _cacheRequests = Meter.CreateCounter<long>("orders.cache.requests", description: "Order cache lookups");
    }

    public void OrderCreated(string tenant) => _ordersCreated.Add(1, new KeyValuePair<string, object?>("tenant", tenant));

    public void PublishFailed(string broker) => _publishFailures.Add(1, new KeyValuePair<string, object?>("broker", broker));

    public void Cache(string result) => _cacheRequests.Add(1, new KeyValuePair<string, object?>("result", result));
}
