using Confluent.Kafka;
using Npgsql;
using RabbitMQ.Client;
using StackExchange.Redis;

namespace Orders.Api.Infrastructure;

/// <summary>
/// Settings from the standard platform environment variables (docs/conventions.md). appsettings*.json hold
/// defaults under the same keys, so an injected env var always wins.
/// </summary>
public sealed record PlatformSettings
{
    public required string AppName { get; init; }
    public required string AppVersion { get; init; }
    public required string TenantId { get; init; }
    public required string Environment { get; init; }
    public required string OtlpEndpoint { get; init; }

    /// <summary>True when charts/microservice injected the OpenTelemetry .NET auto-instrumentation (CLR profiler).</summary>
    public bool AutoInstrumentationInjected { get; init; }

    public required string DbHost { get; init; }
    public int DbPort { get; init; }
    public required string DbName { get; init; }
    public required string DbUser { get; init; }
    public required string DbPassword { get; init; }

    public required string RedisHost { get; init; }
    public int RedisPort { get; init; }
    public string? RedisPassword { get; init; }
    public int RedisDb { get; init; }
    public required string RedisKeyPrefix { get; init; }

    public required string RabbitMqHost { get; init; }
    public int RabbitMqPort { get; init; }
    public required string RabbitMqUser { get; init; }
    public required string RabbitMqPassword { get; init; }
    public required string RabbitMqVhost { get; init; }

    public required string KafkaBootstrapServers { get; init; }
    public required string KafkaClientId { get; init; }
    public required string KafkaSecurityProtocol { get; init; }
    public required string KafkaSaslMechanism { get; init; }
    public string? KafkaUsername { get; init; }
    public string? KafkaPassword { get; init; }
    public string? KafkaSslCaFile { get; init; }
    public required string KafkaTopicPrefix { get; init; }
    public required string KafkaOrdersTopic { get; init; }
    public required string RabbitMqExchange { get; init; }
    public required string RabbitMqRoutingKey { get; init; }
    public int CacheTtlSeconds { get; init; }
    public int DbMaxPoolSize { get; init; }

    public static PlatformSettings From(IConfiguration c)
    {
        var topicPrefix = c["KAFKA_TOPIC_PREFIX"] ?? "platform.";
        return new PlatformSettings
        {
            AppName = c["APP_NAME"] ?? "orders",
            AppVersion = c["APP_VERSION"] ?? "dev",
            TenantId = c["TENANT_ID"] is { Length: > 0 } t ? t : "shared",
            Environment = c["ENVIRONMENT"] ?? "local",
            OtlpEndpoint = c["OTEL_EXPORTER_OTLP_ENDPOINT"] ?? string.Empty,
            AutoInstrumentationInjected = !string.IsNullOrEmpty(c["OTEL_DOTNET_AUTO_HOME"]),
            DbHost = c["DB_HOST"] ?? "localhost",
            DbPort = c.GetValue("DB_PORT", 5432),
            DbName = c["DB_NAME"] ?? "orders",
            DbUser = c["DB_USER"] ?? "orders",
            DbPassword = c["DB_PASSWORD"] ?? string.Empty,
            RedisHost = c["REDIS_HOST"] ?? "localhost",
            RedisPort = c.GetValue("REDIS_PORT", 6379),
            RedisPassword = c["REDIS_PASSWORD"],
            RedisDb = c.GetValue("REDIS_DB", 0),
            RedisKeyPrefix = c["REDIS_KEY_PREFIX"] ?? string.Empty,
            RabbitMqHost = c["RABBITMQ_HOST"] ?? "localhost",
            RabbitMqPort = c.GetValue("RABBITMQ_PORT", 5672),
            RabbitMqUser = c["RABBITMQ_USER"] ?? "guest",
            RabbitMqPassword = c["RABBITMQ_PASSWORD"] ?? "guest",
            RabbitMqVhost = c["RABBITMQ_VHOST"] ?? "/",
            KafkaBootstrapServers = c["KAFKA_BOOTSTRAP_SERVERS"] ?? "localhost:9092",
            KafkaClientId = c["KAFKA_CLIENT_ID"] is { Length: > 0 } id ? id : c["APP_NAME"] ?? "orders",
            KafkaSecurityProtocol = c["KAFKA_SECURITY_PROTOCOL"] is { Length: > 0 } p ? p : "PLAINTEXT",
            KafkaSaslMechanism = c["KAFKA_SASL_MECHANISM"] is { Length: > 0 } m ? m : "SCRAM-SHA-512",
            KafkaUsername = c["KAFKA_USERNAME"],
            KafkaPassword = c["KAFKA_PASSWORD"],
            KafkaSslCaFile = c["KAFKA_SSL_CA_FILE"],
            KafkaTopicPrefix = topicPrefix,
            // Topic names carry the tenant prefix (Kafka ACLs); an explicit topic (gitops values) wins.
            KafkaOrdersTopic = c["Orders:Kafka:EventsTopic"] ?? c["KAFKA_ORDERS_TOPIC"] ?? $"{topicPrefix}orders-events",
            RabbitMqExchange = c["Orders:Rabbit:Exchange"] ?? "orders.events",
            RabbitMqRoutingKey = c["Orders:Rabbit:RoutingKey"] ?? "order.created",
            CacheTtlSeconds = c.GetValue("Orders:Cache:TtlSeconds", 300),
            DbMaxPoolSize = c.GetValue("Orders:Db:MaxPoolSize", 50),
        };
    }

    /// <summary>
    /// Kafka client security from KAFKA_SECURITY_PROTOCOL / KAFKA_SASL_MECHANISM / KAFKA_USERNAME / KAFKA_PASSWORD
    /// (platform listeners: SASL SCRAM-SHA-512; local compose: PLAINTEXT without credentials).
    /// </summary>
    public void ApplyKafkaSecurity(ClientConfig config)
    {
        config.SecurityProtocol = Enum.Parse<SecurityProtocol>(KafkaSecurityProtocol.Replace("_", string.Empty, StringComparison.Ordinal),
            ignoreCase: true);
        if (KafkaSecurityProtocol.StartsWith("SASL_", StringComparison.OrdinalIgnoreCase))
        {
            config.SaslMechanism = KafkaSaslMechanism.ToUpperInvariant() switch
            {
                "SCRAM-SHA-512" => SaslMechanism.ScramSha512,
                "SCRAM-SHA-256" => SaslMechanism.ScramSha256,
                "PLAIN" => SaslMechanism.Plain,
                var other => throw new InvalidOperationException($"Unsupported KAFKA_SASL_MECHANISM '{other}'"),
            };
            config.SaslUsername = KafkaUsername;
            config.SaslPassword = KafkaPassword;
        }

        if (!string.IsNullOrEmpty(KafkaSslCaFile))
        {
            config.SslCaLocation = KafkaSslCaFile; // Strimzi cluster CA (PEM) for SASL_SSL / SSL
        }
    }

    /// <summary>PgBouncer (transaction pooling) friendly: no reset on close, no auto-prepare, short timeouts.</summary>
    public string PostgresConnectionString => new NpgsqlConnectionStringBuilder
    {
        Host = DbHost,
        Port = DbPort,
        Database = DbName,
        Username = DbUser,
        Password = DbPassword,
        ApplicationName = AppName,
        Timeout = 5,
        CommandTimeout = 10,
        MaxPoolSize = DbMaxPoolSize,
        NoResetOnClose = true,
    }.ConnectionString;

    public ConfigurationOptions RedisOptions()
    {
        var options = new ConfigurationOptions
        {
            Password = string.IsNullOrEmpty(RedisPassword) ? null : RedisPassword,
            DefaultDatabase = RedisDb,
            ClientName = AppName,
            AbortOnConnectFail = false, // start (and serve from the DB) even when Redis is down
            ConnectTimeout = 2000,
            SyncTimeout = 1000,
            AsyncTimeout = 1000,
        };
        options.EndPoints.Add(RedisHost, RedisPort);
        return options;
    }

    public ConnectionFactory RabbitMqFactory() => new()
    {
        HostName = RabbitMqHost,
        Port = RabbitMqPort,
        UserName = RabbitMqUser,
        Password = RabbitMqPassword,
        VirtualHost = RabbitMqVhost,
        ClientProvidedName = AppName,
        AutomaticRecoveryEnabled = true,
        TopologyRecoveryEnabled = true,
        RequestedConnectionTimeout = TimeSpan.FromSeconds(5),
    };
}
