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
`workload-tier` = `edge` | `platform` | `data` | `storage` | `apps` | `observability`.
`storage` nodes (tainted `workload-tier=storage:NoSchedule`) host the in-cluster MinIO tenant on `local-nvme` drives.
Non-Kubernetes inventory groups: `loadbalancers` (HAProxy/keepalived), `vault_servers` (external Vault), `minio_servers` (external MinIO).
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
| `minio-operator` / `minio` | MinIO operator / MinIO tenant `minio` |
| `csi-s3`, `csi-nfs`, `local-path-storage` | Storage drivers |
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
- `local-nvme-minio` — MinIO drives only: maps PVC `dataN-*` to `/mnt/local-nvme/dataN` (one NVMe per drive) on `storage` nodes.
- `local-nvme` — local-path provisioner on `/mnt/local-nvme` (dedicated disk prepared by Ansible `storage_prep`), `WaitForFirstConsumer`;
  fastest option, node-bound: MinIO drives, scratch/generic ephemeral volumes, caches.
- `nfs-rwx` — csi-driver-nfs against an on-prem NFS export (`nfs.storage.example.local:/exports/k8s`); ReadWriteMany shared files.
- `minio-s3` — CSI S3 driver `ru.yandex.s3.csi` (FUSE, geesefs) mounting MinIO buckets as volumes (ReadWriteMany, eventual consistency,
  not for databases). Dynamic volumes are prefixes in bucket `platform-pvc` (platform user, Vault `secret/platform/csi-s3`);
  tenant buckets are mounted through static PVs (`charts/tenant` `data.objectStorage.volumes`) with `tenant-s3-credentials`.

See [storage.md](storage.md) for the decision table (block vs file vs object vs ephemeral).

## Object storage (MinIO)

| Endpoint | Purpose |
|----------|---------|
| `https://minio.minio.svc.cluster.local` (MinIO tenant `minio`, namespace `minio`, S3 API port 443) | In-cluster object storage for applications, per-tenant buckets, CSI S3 mounts |
| `https://minio-console.ops.example.local` | MinIO console via Istio internal gateway |
| `https://s3.example.com` | Optional public S3 endpoint via Kong (pre-signed URLs) |
| `https://minio.storage.example.local:9000` | **External** MinIO on VMs (Ansible `minio_server`, inventory group `minio_servers`) = backup target (CNPG, Velero, Thanos, ES snapshots, Longhorn, dqlite) outside the cluster failure domain |

- Bucket naming: `<tenant>-<purpose>` (e.g. `acme-files`, `shared-files`); platform buckets `platform-*`.
- Per-tenant S3 identity: MinIO user `<tenant>` restricted to `<tenant>-*` buckets; credentials in Vault `secret/tenants/<tenant>/storage`
  (keys `S3_ACCESS_KEY`, `S3_SECRET_KEY`) → Secret `tenant-s3-credentials` in the tenant namespace.
- Env vars injected by `charts/microservice` when object storage is enabled: `S3_ENDPOINT, S3_REGION, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY, S3_FORCE_PATH_STYLE`.
- MinIO root credentials: Vault `secret/platform/minio` (in-cluster) and `secret/platform/minio-external` (VMs).
- Images: MinIO is source-only upstream, so `harbor.ops.example.local/platform/{minio,mc}:<RELEASE tag>` are built from source by
  `.github/workflows/tool-images.yml` (`images/minio`, `images/mc`).

## Load balancing (L7 with optional L4)

```
Internet ─▶ [L7/L4 LB pair: HAProxy + keepalived, inventory group `loadbalancers`]
              public VIP  (lb_public_vip)   ─▶ Kong proxy MetalLB VIP (public-pool)        :443/:80
              internal VIP(lb_internal_vip) ─▶ Istio internal gateway MetalLB VIP (internal-pool) :443
                                            ─▶ Kubernetes API (masters :16443)  [always L4]
                                            ─▶ Kafka external listener :9094      [always L4]
```

- `lb_mode: l7` (default) — HAProxy terminates TLS, HTTP/2, WAF hook, per-IP rate limiting, health checks, sets `X-Forwarded-For`/`X-Forwarded-Proto`,
  re-encrypts to Kong/Istio. Kong/Istio trust the LB IPs for real client IP.
- `lb_mode: l4` — TCP passthrough with PROXY protocol v2; Kong/Istio terminate TLS and read the client IP from PROXY protocol.
- In-cluster L4 is MetalLB (L2 by default, BGP optional); in-cluster L7 is Kong (north-south) and Istio gateways/sidecars (east-west).

## External Vault (optional)

Ansible role `vault_server` can run a standalone Vault HA (raft) cluster on VMs (inventory group `vault_servers`,
`https://vault-ext.example.local:8200`). Uses: Ansible secrets source (`secrets_backend: hashicorp_vault`, lookups via
`community.hashi_vault`), **transit auto-unseal** (key `autounseal-k8s`) for the in-cluster Vault, and optional ESO backend.
`vault_deployment_mode`: `in-cluster` (default) | `external` | `both`.

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
