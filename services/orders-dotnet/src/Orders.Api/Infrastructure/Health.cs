using System.Text.Json;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace Orders.Api.Infrastructure;

/// <summary>Flipped once the host has started (and, locally, migrations ran): drives /health/startup.</summary>
public sealed class StartupState
{
    private volatile bool _started;

    public bool Started
    {
        get => _started;
        set => _started = value;
    }
}

public sealed class StartupHealthCheck(StartupState state) : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult(state.Started ? HealthCheckResult.Healthy() : HealthCheckResult.Unhealthy("starting"));
}

public static class HealthEndpoints
{
    public const string Live = "live";
    public const string Ready = "ready";
    public const string Startup = "startup";

    public static void MapPlatformHealthChecks(this IEndpointRouteBuilder app)
    {
        app.MapHealthChecks("/health/live", Options(Live));
        app.MapHealthChecks("/health/ready", Options(Ready));
        app.MapHealthChecks("/health/startup", Options(Startup));
    }

    private static HealthCheckOptions Options(string tag) => new()
    {
        Predicate = r => r.Tags.Contains(tag),
        ResponseWriter = WriteAsync,
    };

    private static Task WriteAsync(HttpContext context, HealthReport report)
    {
        context.Response.ContentType = "application/json";
        return JsonSerializer.SerializeAsync(context.Response.Body, new
        {
            status = report.Status.ToString(),
            checks = report.Entries.ToDictionary(e => e.Key, e => e.Value.Status.ToString()),
        });
    }
}
