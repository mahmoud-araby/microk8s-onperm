using System.Diagnostics;
using Serilog.Context;

namespace Orders.Api.Infrastructure;

public static class RequestContext
{
    public const string TenantHeader = "X-Tenant-ID";
    public const string CorrelationHeader = "X-Correlation-ID";
    private const string TenantItem = "tenant_id";
    private const string CorrelationItem = "correlation_id";

    public static string GetTenantId(this HttpContext context) => (string)context.Items[TenantItem]!;

    public static string GetCorrelationId(this HttpContext context) => (string)context.Items[CorrelationItem]!;

    /// <summary>
    /// Resolves tenant (X-Tenant-ID set by Kong from the JWT claim, else env TENANT_ID) and correlation id, and pushes
    /// them into the log context and the current span.
    /// </summary>
    public static IApplicationBuilder UseRequestContext(this IApplicationBuilder app, string defaultTenant) =>
        app.Use(async (context, next) =>
        {
            var tenant = context.Request.Headers[TenantHeader].FirstOrDefault() is { Length: > 0 } t ? t : defaultTenant;
            var correlationId = context.Request.Headers[CorrelationHeader].FirstOrDefault() is { Length: > 0 } c
                ? c
                : Guid.NewGuid().ToString();

            context.Items[TenantItem] = tenant;
            context.Items[CorrelationItem] = correlationId;
            context.Response.Headers[CorrelationHeader] = correlationId;
            Activity.Current?.SetTag("tenant.id", tenant).SetTag("correlation.id", correlationId);

            using (LogContext.PushProperty(TenantItem, tenant))
            using (LogContext.PushProperty(CorrelationItem, correlationId))
            {
                await next(context);
            }
        });
}
