using Microsoft.AspNetCore.Diagnostics;
using Npgsql;
using Polly.CircuitBreaker;
using Polly.RateLimiting;
using Polly.Timeout;

namespace Orders.Api.Infrastructure;

/// <summary>Maps dependency failures (open circuit, timeouts, bulkhead rejections, DB outages) to 503 problem details.</summary>
public sealed class DependencyExceptionHandler(IProblemDetailsService problemDetails, ILogger<DependencyExceptionHandler> logger)
    : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext httpContext, Exception exception, CancellationToken cancellationToken)
    {
        var dependency = exception switch
        {
            BrokenCircuitException or TimeoutRejectedException or RateLimiterRejectedException or HttpRequestException => "catalog",
            NpgsqlException or TimeoutException => "database",
            _ => null,
        };
        if (dependency is null)
        {
            return false;
        }

        logger.LogWarning("Dependency {Dependency} unavailable: {Error}", dependency, exception.GetType().Name);
        httpContext.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
        httpContext.Response.Headers.RetryAfter = "2";
        return await problemDetails.TryWriteAsync(new ProblemDetailsContext
        {
            HttpContext = httpContext,
            Exception = exception,
            ProblemDetails = { Title = $"Dependency '{dependency}' is unavailable", Status = StatusCodes.Status503ServiceUnavailable },
        });
    }
}
