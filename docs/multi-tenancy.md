# Multi-tenancy and multiple service versions

The platform hosts many tenants (customers / business units) on one MicroK8s cluster and lets each tenant
run the service versions it chooses, including several major versions of the same service side by side.
Everything is declared in Git: `gitops/tenants/<tenant>/` describes a tenant, `gitops/apps/` is the service
catalogue, and two ApplicationSets turn them into Argo CD Applications.

Related: [conventions](conventions.md), [chart interfaces](chart-interfaces.md),
[capacity planning](capacity-planning.md), [resilience](resilience.md),
[gitops/tenants/README.md](../gitops/tenants/README.md), [gitops/apps/README.md](../gitops/apps/README.md),
[charts/tenant/README.md](../charts/tenant/README.md).

## 1. Tenancy tiers

| | **Shared (pooled)** | **Dedicated namespace** | **Dedicated cluster** (option) |
|---|---|---|---|
| Example | `initech` | `acme`, `globex` | a regulated tenant |
| Workloads | pooled releases in `shared-services` serve all pooled tenants | own releases in `tenant-<t>` | own MicroK8s cluster, same Git repo |
| API host | `api.example.com` (tenant from the JWT claim `tenant` -> `X-Tenant-ID`) | `<t>.api.example.com` | `<t>.api.example.com` (own Kong VIP) |
| Service versions | whatever the pool runs | pinned per tenant | pinned per tenant |
| Data | shared DBs `shared_<svc>`, rows keyed by `tenant_id` (row-level security in the services), vhost `shared`, topics `shared.*` | DB per tenant and service, own vhost, own topic prefix | own CNPG / RabbitMQ / Kafka clusters |
| Quota | shared-services quota + Kong per-tenant limit | own ResourceQuota + Kong per-tenant limit | whole cluster |
| Cost / onboarding | lowest, minutes | medium, minutes | highest, hours (Ansible `site.yml`) |
| Blast radius | pool | tenant namespace | tenant cluster |

A tenant can move up a tier without changing its clients except for the host name: add `services/*.yaml`,
switch `tier: dedicated`, migrate its rows from the pooled databases into `<t>_<svc>`
(logical replication / pg_dump by `tenant_id`), then flip DNS / clients to `<t>.api.example.com`.

The **dedicated cluster** option reuses the same repository: a second Argo CD (or a second cluster
destination in the same Argo CD) points the ApplicationSets at `gitops/tenants/<t>/` with
`destination.server` set to that cluster, and the tenant's own data services are declared from
`gitops/platform/data/*` with that cluster's values. Use it for hard regulatory isolation, a separate
failure domain, or when a tenant's load (see capacity planning, "shard by tenant") warrants it.

## 2. How a tenant is materialised

```
gitops/tenants/acme/tenant.yaml ──(ApplicationSet tenants, wave 10)──> Application tenant-acme ──> charts/tenant
    Namespace tenant-acme (PSA restricted, istio-injection), ResourceQuota, LimitRange, RBAC, NetworkPolicies,
    PeerAuthentication STRICT, Sidecar, AuthorizationPolicies, SecretStore vault-tenant, Kong consumer,
    ConfigMap tenant-platform-endpoints
    data-postgres : Database acme-orders|payments|catalog (owners acme_*), role/grant hook Jobs
    data-rabbitmq : Vhost acme, Users acme-orders|acme-payments, Permissions, DLX, Policy quorum-dlx
    data-kafka    : KafkaTopics acme.orders-events|..., KafkaUsers acme-orders|... (prefix ACLs, quotas)
  + gitops/tenants/acme/configmaps/*  (Ansible k8s_configmaps output)

gitops/tenants/acme/services/orders-v2.yaml ──(ApplicationSet services, wave 20)──> Application acme-orders-v2
    charts/microservice with gitops/apps/orders/values.yaml + values-v2.yaml + tenants/acme/values-microservice.yaml
    + tenant wiring (tenant=acme, kong.host=acme.api.example.com, db acme_orders, vhost acme, prefix acme.)
```

## 3. Isolation layers

| Layer | Mechanism | Where |
|-------|-----------|-------|
| Identity | Keycloak **realm per tenant**; JWT claim `tenant`; Kong `jwt` plugin maps the realm issuer (`iss`) to the tenant's KongConsumer | Keycloak, charts/tenant `kong.consumer` |
| Namespace | `tenant-<t>` per dedicated tenant; labels `platform.example.com/tenant`, `platform.example.com/tier` | charts/tenant |
| Pod security | PSA `restricted` (enforce/audit/warn), non-root UID 10001, read-only root FS; Kyverno policies | charts/tenant, gitops/platform/core/kyverno |
| Kubernetes RBAC | Keycloak groups `<t>-admins` / `<t>-devs` / `<t>-viewers` -> ClusterRoles `admin` / `edit` / `view` in the tenant namespace only; `tenant-delivery` Role for Rollouts promote/abort | charts/tenant `rbac` |
| Argo CD RBAC | AppProjects `tenants` / `apps` restrict destinations; recommended policy: tenant groups get read + sync on `apps/<t>-*` only | gitops/bootstrap/projects |
| Quota | ResourceQuota (CPU/memory requests, limits.memory, pods, PVCs, storage, no LoadBalancer/NodePort, object counts, no `longhorn-db`), LimitRange defaults/maximums | charts/tenant `quota`, `limitRange` |
| Network (L3/4) | NetworkPolicy default deny ingress+egress; allow DNS, same namespace, ingress from kong / istio-internal / istio-system / monitoring / observability, egress to data-* / integration / observability / istio-system / istio-egress | charts/tenant `networkPolicy` (+ per-release policies) |
| Mesh (L7) | PeerAuthentication STRICT mTLS; AuthorizationPolicy `allow-nothing` + ALLOW from same namespace, kong, istio-internal (+ integration), metrics from monitoring; Sidecar egress scope + `REGISTRY_ONLY` | charts/tenant `istio` |
| Secrets | Vault path `secret/tenants/<t>/*`; namespaced SecretStore with Vault role `tenant-<t>` that can only read that path | charts/tenant `externalSecrets` |
| PostgreSQL | **database per tenant and service** `<t>_<svc>` owned by role `<t>_<svc>`; `CONNECT`/`TEMP` revoked from `PUBLIC` so no tenant role can connect to another tenant's database; per-role connection limit | charts/tenant `data.postgres` |
| RabbitMQ | **vhost per tenant**; users `<t>-<svc>` with permissions only on that vhost; quorum queues, DLX + delivery-limit policy | charts/tenant `data.rabbitmq` |
| Kafka | **topic prefix** `<t>.`; KafkaUser `<t>-<svc>` (SCRAM-SHA-512) with prefix ACLs on topics, consumer groups and transactional ids; per-user byte-rate / request quotas | charts/tenant `data.kafka` |
| Redis | logical **DB index** per dedicated tenant + **key prefix** `<t>:<svc>:` (pooled: `shared:` + tenant in the key) | tenant.yaml `data.redis`, `values-microservice.yaml` |
| Telemetry | every log line / span / metric carries `tenant_id`; logs indexed per namespace (`logs-<namespace>`), so dashboards and Kibana spaces can be scoped per tenant | conventions, observability |

Pooled tenants rely on application-level isolation inside the shared releases: the tenant is taken only from
the validated JWT (`X-Tenant-ID` set by Kong, never from the client), every query is filtered by `tenant_id`
(PostgreSQL row-level security as a second line of defence), cache keys and message headers include the tenant.

## 4. Noisy-neighbour controls

| Resource | Control |
|----------|---------|
| CPU / memory | ResourceQuota per tenant namespace; LimitRange defaults; HPA/KEDA `maxReplicas` ceilings per release (a tenant cannot scale past its quota) |
| Scheduling priority | PriorityClasses `platform-critical`, `data-critical`, `apps-high`, `apps-default`, `batch-low` (cluster-wide, gitops/platform). Tenants are forbidden from `platform-critical` / `data-critical` / `system-*` by a scoped ResourceQuota (`pods: 0`); `apps-high` can be capped per tenant (`quota.appsHighPods`) |
| API traffic | Kong **per-tenant** rate limit: a `rate-limiting` plugin on the tenant's KongConsumer (`limit_by: consumer`, Redis counters shared by all Kong replicas). Kong's plugin precedence makes the consumer-scoped limit override the per-route limit, so it applies to the tenant across all its routes; pooled and dedicated tenants alike |
| Mesh | DestinationRule connection pools and outlier detection per release (bulkheads, circuit breakers) |
| PostgreSQL | per-role `CONNECTION LIMIT`, PgBouncer transaction pooling, per-release pool sizes; very large tenants move to a dedicated CNPG cluster |
| RabbitMQ | vhost per tenant (optional vhost connection/queue limits), quorum queue `delivery-limit`, DLQ `x-max-length` with drop-head |
| Kafka | per KafkaUser `producerByteRate`, `consumerByteRate`, `requestPercentage`, `controllerMutationRate`; partitions sized per tenant |
| Storage | PVC count and total storage quota; `longhorn-db` class forbidden for tenants |
| Blast radius | PDBs, topology spread, separate releases per tenant (a bad tenant config cannot break another tenant's pods) |

## 5. Version pinning per tenant

- The catalogue (`gitops/apps/<svc>/values-<version>.yaml`) defines the **current image of each major version**.
- A tenant **consumes** a version by having `gitops/tenants/<t>/services/<svc>-<version>.yaml`. Several majors
  can coexist (`acme` runs `orders-v1` and `orders-v2` during its migration); Kong routes `/orders/v1/*` and
  `/orders/v2/*` (or the `X-API-Version` header) to the matching release.
- A tenant can **freeze** an image with `imageTag:` in the descriptor (`acme` payments during an audit).
- New images reach tenants **ring by ring** (ApplicationSet RollingSync on the `release-ring` label:
  `canary` -> `early` -> `general`); inside each release Argo Rollouts runs a canary with Prometheus analysis
  and aborts automatically. `globex` is the canary-ring tenant and the early adopter of `catalog v2`.
- A version is **sunset** by deleting descriptors tenant by tenant and finally the catalogue file.

Details: [gitops/apps/README.md](../gitops/apps/README.md).

## 6. Onboarding automation

1. `cp -r gitops/tenants/_template gitops/tenants/<t>`, fill `tenant.yaml` (tier, quota, data) and the
   `services/` descriptors (dedicated tier only).
2. Seed identity and secrets: Keycloak realm `<t>` (groups + `tenant` claim mapper), Vault
   `secret/tenants/<t>/<svc>` (`DB_PASSWORD`, `RABBITMQ_PASSWORD`, `KAFKA_PASSWORD`, ...),
   `secret/tenants/<t>/keycloak` (`realm_public_key`), Vault role `tenant-<t>`.
3. Tenant configuration: the Ansible role **`k8s_configmaps`** (`make configmaps ENV=production`, mode
   `gitops`) renders the layered tenant/service ConfigMaps (global < environment < tenant < service) into
   `gitops/tenants/<t>/configmaps/`. The tenants ApplicationSet adds that directory as a second source of
   `tenant-<t>`, so the ConfigMaps are reviewed and synced like everything else. Each tenant keeps at least
   `configmaps/tenant-feature-flags.yaml` so the directory source never points at a missing path.
4. Pull request -> merge. `tenant-<t>` (wave 10) builds the landing zone and provisions data (roles and
   databases in `pg-main`, vhost and users in RabbitMQ, topics and users in Kafka); the service
   Applications (wave 20) deploy the pinned versions.
5. Offboarding is the reverse and is documented in [gitops/tenants/README.md](../gitops/tenants/README.md).

## 7. Capacity notes

- ~1M users are split across the pool and the dedicated tenants; the pooled releases carry the highest
  ceilings (orders v2 up to 120 replicas, catalog up to 150) and dedicated tenants are sized by quota.
- Every tenant adds per-tenant objects to the shared data services (one database per service, one vhost,
  a few topics). Keep the number of dedicated tenants on `pg-main` within its connection budget
  (sum of role connection limits behind PgBouncer) and move heavy tenants to a dedicated data cluster.
- Istio `Sidecar` resources keep Envoy configuration small as the number of tenant namespaces grows.
