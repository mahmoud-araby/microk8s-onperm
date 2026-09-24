# Platform Conventions (contract between all components)

Every directory in this repository follows these conventions. When you change a
name here, change it everywhere.

## Repository layout

| Path | Owner / purpose |
|------|-----------------|
| `ansible/` | Bare-metal / VM provisioning of the MicroK8s HA cluster, OS hardening, addons, Argo CD bootstrap, ConfigMap generation |
| `gitops/bootstrap/` | Argo CD root "app-of-apps", AppProjects, category Applications |
| `gitops/platform/core/<component>/` | Networking, security, delivery: Istio, Kong, MetalLB, cert-manager, Longhorn, Vault, External Secrets, Keycloak, Kyverno, Argo Rollouts, KEDA, Velero, Harbor |
| `gitops/platform/data/<component>/` | PostgreSQL (CloudNativePG), Redis (+Sentinel), RabbitMQ, Kafka (Strimzi), WSO2 Micro Integrator, hybrid ServiceEntries |
| `gitops/platform/observability/<component>/` | Prometheus/Grafana/Alertmanager, ECK (Elasticsearch/Kibana/APM), Fluent Bit, OpenTelemetry Collector, Kiali, dashboards, alerts, SLOs |
| `gitops/apps/` | Service catalogue: default values per service and per version + ApplicationSets |
| `gitops/tenants/<tenant>/` | Tenant definition (`tenant.yaml`) + deployed service versions (`services/*.yaml`) |
| `charts/microservice` | Generic Helm chart for .NET / Java / Python services |
| `charts/frontend` | Helm chart for SPA/static frontend hosting (nginx) |
| `charts/tenant` | Helm chart for a tenant landing zone (namespace, quotas, RBAC, network policies) |
| `services/` | Reference microservices (.NET, Java, Python) + frontend, with Dockerfiles |
| `.github/workflows/` | CI: build, test, scan, push to Harbor, bump GitOps image tags |
| `docs/` | Architecture, capacity planning, runbooks |

Every platform component directory contains:
- `application.yaml` — an Argo CD `Application` (namespace `argocd`, `project` = category name: `core`, `data` or `observability`) with a `argocd.argoproj.io/sync-wave` annotation.
- `values.yaml` if it is a Helm chart (referenced through a multi-source Application: `ref: values` on this git repo and `valueFiles: [$values/gitops/platform/<category>/<component>/values.yaml]`).
- `manifests/` for raw Kubernetes manifests / CRs (a second source with `path: gitops/platform/<category>/<component>/manifests`).

Git repository URL: `https://github.com/mahmoud-araby/microk8s-onperm.git`, `targetRevision: main`.

## Sync waves

| Wave | What |
|------|------|
| -20 | CRDs / namespaces |
| -15 | MetalLB, Longhorn, cert-manager |
| -10 | Istio base/istiod, Vault, External Secrets, Kyverno, operators (CNPG, RabbitMQ, Strimzi, ECK, Rollouts, KEDA) |
| -5  | Gateways (Istio ingress/internal/egress, Kong), Keycloak, Harbor, Velero, ClusterIssuers, ClusterSecretStore |
| 0   | Data services (Postgres, Redis, RabbitMQ, Kafka, Micro Integrator) |
| 5   | Observability stack |
| 10  | Tenants |
| 20  | Applications |

## Nodes

MicroK8s HA: 3+ nodes are control plane (dqlite voters). Worker pools are identified by the label
`workload-tier` = `edge` | `platform` | `data` | `apps` | `observability`.
Data and edge nodes carry taints `workload-tier=data:NoSchedule` / `workload-tier=edge:NoSchedule`;
components targeting them add the matching toleration + nodeSelector/affinity.

## Namespaces

| Namespace | Content |
|-----------|---------|
| `argocd`, `argo-rollouts` | GitOps + progressive delivery |
| `istio-system` | istiod, Kiali |
| `istio-ingress` | Istio **public** ingress gateway (only for non-API traffic when needed) |
| `istio-internal` | Istio **internal** gateway (private VIP, east-west / hybrid / partner VPN) |
| `istio-egress` | Istio egress gateway (hybrid & external services) |
| `kong` | Kong **external** API gateway (public VIP) |
| `metallb-system`, `cert-manager`, `longhorn-system`, `vault`, `external-secrets`, `keycloak`, `kyverno`, `velero`, `harbor`, `keda` | Platform |
| `cnpg-system` / `data-postgres` | CloudNativePG operator / clusters |
| `data-redis` | Redis replication + Sentinel |
| `rabbitmq-system` / `data-rabbitmq` | RabbitMQ operator / cluster |
| `data-kafka` | Strimzi operator + Kafka (KRaft) cluster |
| `integration` | WSO2 Micro Integrator |
| `monitoring` | kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Thanos |
| `elastic-system` / `logging` | ECK operator / Elasticsearch, Kibana, APM Server, Fluent Bit |
| `observability` | OpenTelemetry Collector |
| `tenant-<name>` | One namespace per tenant (e.g. `tenant-acme`, `tenant-globex`) |
| `shared-services` | Services shared by all tenants (pooled tier) |

## Well-known endpoints (in-cluster DNS)

| Service | Endpoint |
|---------|----------|
| PostgreSQL (rw, via PgBouncer) | `pg-main-pooler-rw.data-postgres.svc.cluster.local:5432` |
| PostgreSQL (rw direct / ro replicas) | `pg-main-rw.data-postgres.svc.cluster.local:5432` / `pg-main-ro.data-postgres.svc.cluster.local:5432` |
| Redis (master) | `redis.data-redis.svc.cluster.local:6379` |
| Redis Sentinel | `redis-sentinel.data-redis.svc.cluster.local:26379`, master set `mymaster` |
| RabbitMQ AMQP / management | `rabbitmq.data-rabbitmq.svc.cluster.local:5672` / `:15672` |
| Kafka bootstrap (plain / TLS) | `kafka-kafka-bootstrap.data-kafka.svc.cluster.local:9092` / `:9093` |
| Kafka HTTP bridge | `kafka-bridge-bridge-service.data-kafka.svc.cluster.local:8080` |
| WSO2 Micro Integrator | `micro-integrator.integration.svc.cluster.local:8290` (HTTP) / `:8253` (HTTPS) |
| OpenTelemetry Collector | `otel-collector.observability.svc.cluster.local:4317` (gRPC) / `:4318` (HTTP) |
| Elasticsearch | `elasticsearch-es-http.logging.svc.cluster.local:9200` |
| Elastic APM Server | `apm-server-apm-http.logging.svc.cluster.local:8200` |
| Prometheus | `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090` |
| Keycloak | `keycloak.keycloak.svc.cluster.local:8080` |
| Vault | `vault.vault.svc.cluster.local:8200` |

## External hostnames (replace `example.com`)

| Host | Routed by |
|------|-----------|
| `api.example.com` | Kong (public VIP) → shared/pooled services, `/<service>/<version>/...`, tenant taken from JWT claim `tenant` |
| `<tenant>.api.example.com` | Kong → the tenant's dedicated service releases, `/<service>/<version>/...` |
| `<tenant>.app.example.com`, `app.example.com` | Kong → frontend |
| `*.internal.example.local` | Istio internal gateway (private VIP) |
| `argocd.ops.example.local`, `grafana.ops.example.local`, `kibana.ops.example.local`, `kiali.ops.example.local`, `rollouts.ops.example.local`, `vault.ops.example.local`, `harbor.ops.example.local`, `keycloak.ops.example.local`, `rabbitmq.ops.example.local` | Istio internal gateway (ops tooling is never public) |

MetalLB address pools: `public-pool` (Kong, public ingress), `internal-pool` (Istio internal gateway, Kafka external listener, ops).

## Storage classes

- `longhorn` (default) — 3 replicas, for general stateful workloads.
- `longhorn-db` — 1 replica, `dataLocality: strict-local`; for systems that replicate themselves (Postgres, Kafka, RabbitMQ, Redis, Elasticsearch).

## Secrets and certificates

- Vault is the source of truth. External Secrets Operator `ClusterSecretStore` named **`vault-backend`** (KV v2 mount `secret`).
  Paths: `secret/platform/<component>`, `secret/tenants/<tenant>/<service>`.
- cert-manager `ClusterIssuer`s: **`internal-ca`** (on-prem CA; default for internal hosts) and **`letsencrypt-prod`** (public hosts).

## Monitoring contract

- Prometheus picks up **every** `ServiceMonitor` / `PodMonitor` / `PrometheusRule` in every namespace (no release label needed).
- Every workload exposes Prometheus metrics; every service sends traces/metrics/logs via OTLP to the OpenTelemetry Collector, which fans out to Elastic APM and Prometheus.
- Logs are JSON on stdout, shipped by Fluent Bit to Elasticsearch, index pattern `logs-<namespace>`.

## Microservice contract (all languages)

| Item | Value |
|------|-------|
| HTTP port | `8080` (container), Service port `80` named `http` |
| Liveness | `GET /health/live` |
| Readiness | `GET /health/ready` (checks DB/Redis/broker) |
| Startup | `GET /health/startup` |
| Metrics | `GET /metrics` (Prometheus format) on port 8080 |
| Graceful shutdown | handle SIGTERM, drain within 25s (`terminationGracePeriodSeconds: 30`, preStop sleep 5s) |
| Logs | JSON to stdout incl. `trace_id`, `span_id`, `tenant_id` |
| Tenant | header `X-Tenant-ID` (set by Kong from JWT claim) + env `TENANT_ID` |
| Correlation | header `X-Correlation-ID` (Kong correlation-id plugin), W3C `traceparent` |
| Runs as | non-root UID 10001, read-only root filesystem |

Standard environment variables injected by the chart:
`APP_NAME, APP_VERSION, TENANT_ID, ENVIRONMENT, OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_RESOURCE_ATTRIBUTES,
DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, REDIS_HOST, REDIS_PORT, REDIS_PASSWORD,
RABBITMQ_HOST, RABBITMQ_PORT, RABBITMQ_USER, RABBITMQ_PASSWORD, KAFKA_BOOTSTRAP_SERVERS`.

## Multiple versions of the same service

A service major version is deployed as its own Helm release named `<service>-<version>` (e.g. `orders-v1`, `orders-v2`)
with labels `app.kubernetes.io/name=<service>`, `app.kubernetes.io/version=<imageTag>`, `version=<version>`.
Versions run side by side; Kong routes `/<service>/v1/*` → `orders-v1`, `/<service>/v2/*` → `orders-v2` (or header `X-API-Version`).
Inside a version, Argo Rollouts performs canary releases with Istio weighted routing and Prometheus analysis.
Each tenant pins the versions it consumes in `gitops/tenants/<tenant>/services/<service>-<version>.yaml`.

## Labels

`app.kubernetes.io/name`, `app.kubernetes.io/instance`, `app.kubernetes.io/version`, `app.kubernetes.io/component`,
`app.kubernetes.io/part-of`, `app.kubernetes.io/managed-by`, `version`, `platform.example.com/tenant`,
`platform.example.com/language` (`dotnet` | `java` | `python` | `static`).
