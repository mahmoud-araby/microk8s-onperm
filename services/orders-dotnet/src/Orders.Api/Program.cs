using System.Threading.RateLimiting;
using Asp.Versioning;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;
using OpenTelemetry;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Orders.Api.Caching;
using Orders.Api.Catalog;
using Orders.Api.Data;
using Orders.Api.Endpoints;
using Orders.Api.Infrastructure;
using Orders.Api.Messaging;
using Prometheus;
using Serilog;
using Serilog.Formatting.Compact;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);
var settings = PlatformSettings.From(builder.Configuration);
builder.Services.AddSingleton(settings);

// ---- Logging: JSON to stdout with trace_id / span_id / tenant_id -------------------------------------------------
builder.Host.UseSerilog((context, services, logger) => logger
    .ReadFrom.Configuration(context.Configuration)
    .Enrich.FromLogContext()
    .Enrich.With<ActivityEnricher>()
    .Enrich.WithProperty("service", settings.AppName)
    .Enrich.WithProperty("version", settings.AppVersion)
    .Enrich.WithProperty("environment", settings.Environment)
    .WriteTo.Console(new RenderedCompactJsonFormatter()));

// ---- Graceful shutdown: SIGTERM → stop accepting, drain within 25s (terminationGracePeriodSeconds 30) --------------
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(25));

// ---- OpenTelemetry: traces + metrics via OTLP (endpoint/protocol from OTEL_EXPORTER_OTLP_* env) --------------------
// When the chart injects the .NET auto-instrumentation agent it owns the pipeline (AspNetCore, HttpClient, Npgsql and
// the "Orders.*" ActivitySource via OTEL_DOTNET_AUTO_TRACES_ADDITIONAL_SOURCES); registering the SDK too would
// duplicate spans.
if (!settings.AutoInstrumentationInjected)
{
    var otel = builder.Services.AddOpenTelemetry()
        .ConfigureResource(r => r
            .AddService(settings.AppName, serviceVersion: settings.AppVersion)
            .AddAttributes([
                new("deployment.environment.name", settings.Environment),
                new("tenant.id", settings.TenantId),
            ]))
        .WithTracing(t => t
            .AddAspNetCoreInstrumentation(o => o.Filter = ctx =>
                !ctx.Request.Path.StartsWithSegments("/health") && !ctx.Request.Path.StartsWithSegments("/metrics"))
            .AddHttpClientInstrumentation()
            .AddNpgsql()
            .AddSource(OrdersMetrics.ActivitySource.Name))
        .WithMetrics(m => m
            .AddAspNetCoreInstrumentation()
            .AddHttpClientInstrumentation()
            .AddRuntimeInstrumentation()
            .AddMeter(OrdersMetrics.MeterName));
    if (!string.IsNullOrEmpty(settings.OtlpEndpoint))
    {
        otel.UseOtlpExporter(); // honours OTEL_EXPORTER_OTLP_PROTOCOL (chart: http/protobuf on :4318)
    }
}

builder.Services.AddSingleton<OrdersMetrics>();

// ---- Data: PostgreSQL (EF Core + Npgsql) and Redis ----------------------------------------------------------------
builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(settings.PostgresConnectionString).Build());
builder.Services.AddDbContext<OrdersDbContext>((sp, o) => o.UseNpgsql(sp.GetRequiredService<NpgsqlDataSource>(),
    npgsql => npgsql.EnableRetryOnFailure(maxRetryCount: 3, maxRetryDelay: TimeSpan.FromSeconds(2), errorCodesToAdd: null)));
builder.Services.AddSingleton<IConnectionMultiplexer>(_ => ConnectionMultiplexer.Connect(settings.RedisOptions()));
builder.Services.AddSingleton<IOrderCache, RedisOrderCache>();

// ---- Messaging: RabbitMQ + Kafka ----------------------------------------------------------------------------------
builder.Services.AddSingleton<RabbitMqConnection>();
builder.Services.AddSingleton<RabbitMqEventPublisher>();
builder.Services.AddSingleton<KafkaEventPublisher>();
builder.Services.AddSingleton<IOrderEventsPublisher, OrderEventsPublisher>();

// ---- Catalog client: HttpClientFactory + standard resilience pipeline (see CatalogClientRegistration) -------------
builder.Services.AddCatalogClient(builder.Configuration);

builder.Services.AddScoped<OrderService>();

// ---- API: versioning, problem details, server-side bulkhead for writes --------------------------------------------
builder.Services.AddApiVersioning(o =>
{
    o.DefaultApiVersion = ApiVersionParser.Default.Parse(builder.Configuration["API_DEFAULT_VERSION"] ?? "1.0");
    o.AssumeDefaultVersionWhenUnspecified = true;
    o.ReportApiVersions = true;
    o.ApiVersionReader = ApiVersionReader.Combine(
        new HeaderApiVersionReader("X-API-Version"),
        new QueryStringApiVersionReader("api-version"));
});
builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<DependencyExceptionHandler>();
builder.Services.AddRateLimiter(o =>
{
    // 503 lets the mesh retry on another replica instead of queueing forever on this one.
    o.RejectionStatusCode = StatusCodes.Status503ServiceUnavailable;
    o.AddConcurrencyLimiter(OrdersApi.WritePolicy, c =>
    {
        c.PermitLimit = builder.Configuration.GetValue("Bulkhead:MaxConcurrentWrites", 64);
        c.QueueLimit = builder.Configuration.GetValue("Bulkhead:QueueLimit", 128);
        c.QueueProcessingOrder = QueueProcessingOrder.OldestFirst;
    });
});

// ---- Health: live (process), ready (dependencies), startup (host started) ------------------------------------------
builder.Services.AddSingleton<StartupState>();
builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: [HealthEndpoints.Live])
    .AddCheck<StartupHealthCheck>("startup", tags: [HealthEndpoints.Startup])
    .AddNpgSql(sp => sp.GetRequiredService<NpgsqlDataSource>(), name: "postgres", tags: [HealthEndpoints.Ready],
        timeout: TimeSpan.FromSeconds(2))
    .AddRedis(sp => sp.GetRequiredService<IConnectionMultiplexer>(), name: "redis", failureStatus: HealthStatus.Degraded,
        tags: [HealthEndpoints.Ready], timeout: TimeSpan.FromSeconds(1))
    .AddRabbitMQ(sp => sp.GetRequiredService<RabbitMqConnection>().GetAsync(), name: "rabbitmq",
        tags: [HealthEndpoints.Ready], timeout: TimeSpan.FromSeconds(2));

var app = builder.Build();

// `dotnet Orders.Api.dll --migrate` runs EF migrations and exits (chart: startup.migrations init container).
if (args.Contains("--migrate") || builder.Configuration.GetValue("DB_AUTO_MIGRATE", false))
{
    await using var scope = app.Services.CreateAsyncScope();
    await scope.ServiceProvider.GetRequiredService<OrdersDbContext>().Database.MigrateAsync();
    if (args.Contains("--migrate"))
    {
        return;
    }
}

app.Lifetime.ApplicationStarted.Register(() => app.Services.GetRequiredService<StartupState>().Started = true);

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseRequestContext(settings.TenantId);
app.UseSerilogRequestLogging(o => o.GetLevel = (ctx, _, ex) =>
    ex is not null || ctx.Response.StatusCode >= 500 ? Serilog.Events.LogEventLevel.Error
    : ctx.Request.Path.StartsWithSegments("/health") || ctx.Request.Path.StartsWithSegments("/metrics")
        ? Serilog.Events.LogEventLevel.Verbose
        : Serilog.Events.LogEventLevel.Information);
app.UseHttpMetrics();
app.UseRateLimiter();

app.MapPlatformHealthChecks();
app.MapMetrics("/metrics");
app.MapOrdersApi();

await app.RunAsync();

public partial class Program;
