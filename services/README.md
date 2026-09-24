# Reference microservices

Four small, production-style services that implement the platform **microservice contract**
([docs/conventions.md](../docs/conventions.md)) in each supported stack. They are the templates teams copy, and
they are what `gitops/apps/<service>/` deploys through `charts/microservice` / `charts/frontend`.

| Directory | Service | Stack | Data / messaging | Resilience shown |
|-----------|---------|-------|------------------|------------------|
| [`orders-dotnet/`](orders-dotnet) | `orders` | .NET 8, ASP.NET Core minimal APIs, EF Core | PostgreSQL, Redis (cache-aside + Idempotency-Key), publishes `OrderCreated` to RabbitMQ (`orders.events`/`order.created`) and Kafka (`<prefix>orders-events`) | `Microsoft.Extensions.Http.Resilience` standard pipeline on the catalog client (concurrency limiter = bulkhead, total/attempt timeouts, retries with jittered exponential backoff, circuit breaker); server-side concurrency limiter (bulkhead) on writes; EF Core retrying execution strategy |
| [`payments-java/`](payments-java) | `payments` | Java 21, Spring Boot 3.5, Maven | Consumes RabbitMQ `payments.order-created` (manual ack, quorum queue, DLQ) and Kafka `<prefix>orders-events` (DLT); PostgreSQL via JPA + Flyway | Resilience4j `@Retry` (exponential + jitter), `@CircuitBreaker`, `@TimeLimiter`, thread-pool `@Bulkhead` around the external payment provider (reached through the Istio egress gateway) |
| [`catalog-python/`](catalog-python) | `catalog` | Python 3.12, FastAPI, gunicorn + uvicorn workers | PostgreSQL (SQLAlchemy async / asyncpg), Redis cache-aside with TTL jitter and stampede lock, optional Kafka consumer (`<prefix>inventory-events`) | tenacity retries (full jitter), own async circuit breaker, semaphore bulkhead; Redis failures degrade to the DB |
| [`web-frontend/`](web-frontend) | `web` | Vite + React 19 + TypeScript, nginx-unprivileged | Calls `/orders/v1/...` and `/catalog/v1/...` through Kong | Runtime config from `/config.js` (no rebuild per tenant), OIDC login (Keycloak via `oidc-client-ts`) |

## How each service maps to the contract

| Contract item | orders (.NET) | payments (Java) | catalog (Python) | web (nginx) |
|---------------|---------------|-----------------|------------------|-------------|
| Port 8080 | `ASPNETCORE_HTTP_PORTS=8080` (image) / `ASPNETCORE_URLS` (chart) | `server.port: 8080` | gunicorn `bind 0.0.0.0:8080` | nginx-unprivileged listens on 8080 |
| `/health/live` | health checks tagged `live` (process only) | actuator group `live` (`livenessState`, `ping`) | always 200 while the event loop runs | static 200 |
| `/health/ready` | tag `ready`: Postgres, RabbitMQ (unhealthy → 503), Redis (degraded → still 200) | group `ready`: `readinessState`, `db`, `rabbit` | Postgres critical; Redis/Kafka reported as `DEGRADED` | static 200 |
| `/health/startup` | tag `startup`: set on `ApplicationStarted` | group `startup`: `livenessState`, `db` | 200 after the lifespan startup finished | static 200 |
| `/metrics` | prometheus-net (`http_request_duration_seconds`, .NET meters incl. `orders_api_*`) | Micrometer Prometheus registry (`management.endpoints.web.path-mapping.prometheus=metrics`) | prometheus-fastapi-instrumentator + `prometheus_client` (multiprocess mode via `PROMETHEUS_MULTIPROC_DIR`) | `stub_status` on `/nginx_status` for the exporter sidecar |
| JSON logs with `trace_id`, `span_id`, `tenant_id` | Serilog `RenderedCompactJsonFormatter` + `ActivityEnricher` + `LogContext` | logstash-logback-encoder, MDC `traceId/spanId` renamed to `trace_id/span_id` (or the Java agent's own MDC keys) | structlog JSON, OTel span context + contextvars | JSON `access_log` format |
| `X-Tenant-ID` / `TENANT_ID` | middleware → `HttpContext.Items`, log scope, span tag; all queries tenant-scoped | servlet filter → MDC + request attribute; message header `x-tenant-id` on consumers | ASGI middleware → `request.state`, contextvars | sent by the SPA (Kong overwrites it from the JWT) |
| `X-Correlation-ID` | generated if missing, echoed, forwarded to catalog, copied into events | echoed; read from message headers | generated if missing, echoed | logged |
| W3C `traceparent` | OTel SDK (or the injected auto-instrumentation) + injected into RabbitMQ/Kafka headers | Micrometer Tracing (or the injected Java agent) + Spring AMQP/Kafka observation | OTel SDK; extracted from Kafka headers | logged |
| OTLP | `UseOtlpExporter()` honours `OTEL_EXPORTER_OTLP_ENDPOINT/PROTOCOL` | `management.otlp.tracing` (HTTP, `${OTEL_EXPORTER_OTLP_ENDPOINT}/v1/traces`) | OTLP/HTTP or gRPC per `OTEL_EXPORTER_OTLP_PROTOCOL` | - |
| Graceful shutdown (≤25 s) | `HostOptions.ShutdownTimeout=25s`, Kafka producer flushed on dispose | `server.shutdown=graceful`, `timeout-per-shutdown-phase=20s` | gunicorn `graceful_timeout=25`, lifespan closes consumer/pools | nginx `SIGQUIT` default |
| UID 10001, read-only root FS | `USER 10001` on the chiseled image (default `app` user is 1654), only `/tmp` written | `USER 10001` on `eclipse-temurin:21-jre`, Tomcat basedir in `/tmp` | `USER 10001`, prometheus multiprocess files in `/tmp` | image user 101; chart runs it as 10001 (all writable paths in `/tmp`) |
| Config | standard env vars (`PlatformSettings`) + `Orders__*` keys from `gitops/apps/orders` | `application.yml` placeholders over the standard env vars | `pydantic-settings` over the standard env vars | `window.__CONFIG__` (`apiBaseUrl`, `authUrl`, `tenantId`, branding) |
| DB migrations | `/app/efbundle --connection ...` (chart `startup.migrations`), or `DB_AUTO_MIGRATE=true` locally | Flyway on startup | `python -m app.migrate` (chart `startup.migrations`); auto in `ENVIRONMENT=local` | - |

Kafka: every service honours `KAFKA_BOOTSTRAP_SERVERS`, `KAFKA_SECURITY_PROTOCOL` (`PLAINTEXT`, `SASL_PLAINTEXT`,
`SASL_SSL`), `KAFKA_SASL_MECHANISM` (`SCRAM-SHA-512`), `KAFKA_USERNAME`, `KAFKA_PASSWORD`, `KAFKA_TOPIC_PREFIX`
(topic names are `<prefix><name>`, e.g. `acme.orders-events`), `KAFKA_CONSUMER_GROUP` and `KAFKA_CLIENT_ID`.
For `SASL_SSL`, mount the Strimzi cluster CA and set `KAFKA_SSL_CA_FILE` (.NET, Python) or
`SPRING_KAFKA_SSL_TRUST_STORE_TYPE=PEM` + `SPRING_KAFKA_SSL_TRUST_STORE_LOCATION=file:/path/ca.crt` (Java).

### Application resilience vs. mesh resilience

Istio (`charts/microservice` → `istio.*`) gives connection pools, outlier detection, per-try timeouts and
retries on connection-level failures for every hop. The services add what only the application knows:

- **Which calls are safe to retry.** Orders retries idempotent catalog GETs; `POST /orders` accepts an
  `Idempotency-Key` so a retried request returns the first order instead of creating a duplicate. Payment
  declines (HTTP 402/422) are never retried and never trip the breaker.
- **Retry budgets.** App-level retries are small (2-3 attempts, jittered exponential backoff) because the mesh
  may retry as well; keep `attempts(app) × attempts(mesh)` bounded.
- **Bulkheads.** A slow dependency can only consume its own pool (HTTP concurrency limiter, Resilience4j
  thread-pool bulkhead, asyncio semaphore). Rejections return `503` with `Retry-After`, so Istio retries them on
  another replica.
- **Degradation.** Redis outages fall back to the database, broker outages are logged and counted
  (`orders.events.publish_failures`); the readiness probe only fails for dependencies without a fallback.
- **Messaging.** Manual acks, quorum-queue delivery limit + DLQ, Kafka `DefaultErrorHandler` + `<topic>.DLT`,
  idempotent consumers (unique `(tenant_id, order_id)` in payments) and an idempotent Kafka producer.
  Orders publishes after the DB commit; evolve to a transactional outbox when events must never be lost.

## Local development

Prerequisites: Docker with Compose v2. Toolchains only for running outside containers: .NET 8 SDK, JDK 21 +
Maven 3.9, Python 3.12, Node 22.

```bash
cd services
docker compose up -d --build            # infra + all four services
open http://localhost:8080              # SPA (compose nginx emulates Kong's /<service>/<version> routing)

# or only the infrastructure, then run a service from your IDE / shell:
docker compose up -d postgres redis rabbitmq kafka otel-collector payment-provider
```

| Component | URL / port |
|-----------|-----------|
| web | http://localhost:8080 |
| catalog | http://localhost:8081 (`/products`, `/docs`) |
| orders | http://localhost:8082 (`/orders`, `X-API-Version: 2` for v2) |
| payments | http://localhost:8083 (`/payments`) |
| PostgreSQL | `localhost:5432` (`orders`/`catalog`/`payments`, password = user name) |
| RabbitMQ | `localhost:5672`, management http://localhost:15672 (guest/guest) |
| Kafka | `localhost:29092` (PLAINTEXT) |
| OTLP | `localhost:4317` (gRPC) / `localhost:4318` (HTTP); spans are printed by the collector's `debug` exporter |
| Payment provider mock (WireMock) | http://localhost:8089 |

Containers run exactly like in the cluster: `read_only: true`, a `/tmp` tmpfs, UID 10001, 30 s stop grace.

End-to-end smoke test:

```bash
P=$(curl -s -XPOST localhost:8081/products -H 'Content-Type: application/json' -H 'X-Tenant-ID: acme' \
      -d '{"sku":"anvil","name":"Anvil","price":"49.90","currency":"EUR","stock":10}' | jq -r .id)
curl -s -XPOST localhost:8082/orders -H 'Content-Type: application/json' -H 'X-Tenant-ID: acme' \
     -H 'Idempotency-Key: demo-1' -d "{\"customerId\":\"c-1\",\"currency\":\"EUR\",\"items\":[{\"productId\":\"$P\",\"quantity\":2}]}"
curl -s localhost:8083/payments -H 'X-Tenant-ID: acme'     # -> status CAPTURED
```

Running a service natively against the compose infrastructure:

```bash
# orders
cd orders-dotnet && dotnet test && ASPNETCORE_HTTP_PORTS=8082 DB_AUTO_MIGRATE=true CATALOG_BASE_URL=http://localhost:8081/ \
  KAFKA_BOOTSTRAP_SERVERS=localhost:29092 dotnet run --project src/Orders.Api
# payments
cd payments-java && mvn test && SERVER_PORT=8083 KAFKA_BOOTSTRAP_SERVERS=localhost:29092 \
  PAYMENT_PROVIDER_URL=http://localhost:8089 mvn spring-boot:run
# catalog
cd catalog-python && python3.12 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt && .venv/bin/pytest
PROMETHEUS_MULTIPROC_DIR=/tmp/prom .venv/bin/gunicorn -c gunicorn.conf.py --bind 0.0.0.0:8081
# web (Vite proxies /orders/v1 and /catalog/v1 to the ports above)
cd web-frontend && npm ci && npm test && npm run dev
```

Behind a TLS-intercepting corporate proxy, `docker build` needs the corporate CA in the build stages
(e.g. `PIP_CERT`, `NODE_EXTRA_CA_CERTS`, `update-ca-certificates`, or the JDK `cacerts`); CI runners in the
platform network use the internal Harbor/Nexus mirrors instead.

## CI/CD

| Workflow | Trigger (path filter) | Stages |
|----------|----------------------|--------|
| `ci-dotnet.yml` | `services/orders-dotnet/**` | build + xUnit, CodeQL, NuGet audit + Trivy fs |
| `ci-java.yml` | `services/payments-java/**` | `mvn verify`, CodeQL, Trivy fs (Maven deps) |
| `ci-python.yml` | `services/catalog-python/**` | ruff + pytest, CodeQL, pip-audit + Trivy fs |
| `ci-frontend.yml` | `services/web-frontend/**` | typecheck + vitest + build, CodeQL, npm audit + Trivy fs |
| `_reusable-container.yml` | called by the four above | buildx (GitHub cache) → Trivy image scan (fails on CRITICAL, SARIF uploaded) → SBOM (syft, SPDX) → push `harbor.ops.example.local/platform/<service>:<semver>-<sha>` → cosign sign + SBOM attestation |
| `_reusable-gitops-bump.yml` | after a push to `main` | `yq` sets `.image.tag` in `gitops/apps/<service>/values-v<major>.yaml` and opens a PR: `staging` environment → PR to the staging branch with auto-merge; `production` environment (required reviewers) → PR to `main` |
| `validate-gitops.yml` | `gitops/**`, `charts/**`, `ansible/**` | yamllint, Application sanity check, `helm lint` + `helm template` with every `charts/*/ci/*.yaml`, kubeconform (+ datreeio CRDs catalog), kube-linter, ansible-lint |

The semantic version comes from the build file (`<Version>` in `Orders.Api.csproj`, `pom.xml`, `pyproject.toml`,
`package.json`); its major selects the GitOps values file (`1.x` → `values-v1.yaml`). Third-party actions are pinned
by commit SHA and updated by Dependabot.

Repository settings the pipelines expect:

| Kind | Name | Purpose |
|------|------|---------|
| secret | `HARBOR_USERNAME`, `HARBOR_PASSWORD` | Harbor robot account for `platform/*` |
| secret | `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD` | signing key (public key in the Kyverno `verify-image-signatures` policy); keyless OIDC signing is the fallback |
| secret | `GITOPS_TOKEN` | GitHub App / fine-grained token so GitOps PRs trigger `validate-gitops` (optional) |
| variable | `CI_RUNNER_LABELS` | JSON runner labels for image jobs, e.g. `["self-hosted","linux","platform"]` (Harbor is internal) |
| variable | `GITOPS_STAGING_BRANCH` / `GITOPS_PRODUCTION_BRANCH` | branches tracked by the staging / production Argo CD (default `staging` / `main`) |
| environment | `staging`, `production` | `production` with required reviewers = the promotion approval |

## Adding a new service (any language) - checklist

1. **Scaffold** from the closest reference service; keep the directory name `services/<name>-<stack>/`.
2. **HTTP**: listen on `8080`; expose `/health/live` (no dependency checks), `/health/ready` (dependencies
   without a fallback), `/health/startup`, and Prometheus `/metrics`. Exclude probes/scrapes from tracing.
3. **Config**: read the standard env vars (`APP_NAME`, `APP_VERSION`, `TENANT_ID`, `ENVIRONMENT`, `OTEL_*`,
   `DB_*`, `REDIS_*`, `RABBITMQ_*` incl. `RABBITMQ_VHOST`, `KAFKA_*` incl. SASL and `KAFKA_TOPIC_PREFIX`);
   never bake credentials into images; tenant-specific names come from the prefix/vhost/DB name.
4. **Tenancy**: resolve the tenant from `X-Tenant-ID` (fallback `TENANT_ID`), scope every query and cache key by
   it, propagate `X-Tenant-ID`/`X-Correlation-ID` to HTTP calls and message headers.
5. **Observability**: JSON logs on stdout with `trace_id`, `span_id`, `tenant_id`; OTLP traces/metrics to
   `OTEL_EXPORTER_OTLP_ENDPOINT` (or rely on the chart's auto-instrumentation agent); W3C propagation incl.
   messaging headers.
6. **Resilience**: timeouts on every outbound call, bounded jittered retries only for idempotent operations,
   circuit breaker + bulkhead per dependency, idempotent consumers, DLQ/DLT, graceful degradation.
7. **Shutdown**: handle SIGTERM, stop consuming, drain in-flight work within 25 s (exec-form `ENTRYPOINT`, the
   process is PID 1).
8. **Image**: multi-stage Dockerfile, minimal runtime base, `USER 10001`, write only to `/tmp`, OCI labels,
   `.dockerignore`; migrations runnable as a separate command for `startup.migrations`.
9. **Tests**: unit tests runnable without infrastructure (`dotnet test` / `mvn test` / `pytest` / `vitest`).
10. **CI**: copy the closest `.github/workflows/ci-*.yml`, adjust `paths`, `SERVICE`, `SERVICE_DIR`; add the
    directory to `.github/dependabot.yml` and `.github/CODEOWNERS`.
11. **GitOps**: add `gitops/apps/<service>/values.yaml` + `values-v1.yaml` (language, dependencies, probes are
    the chart defaults) and a descriptor `gitops/tenants/<tenant>/services/<service>-v1.yaml` for a canary tenant.
12. **Docs**: add the service to the tables above and to `docker-compose.yml`.
