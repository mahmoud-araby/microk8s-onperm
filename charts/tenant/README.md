# charts/tenant

Tenant landing zone: one Helm release per tenant, rendered by the ApplicationSet
`gitops/apps/applicationsets/tenants.yaml` from `gitops/tenants/<tenant>/tenant.yaml` (sync wave 10).
The values contract lives in [docs/chart-interfaces.md](../../docs/chart-interfaces.md#chartstenant).
The tenancy model is described in [docs/multi-tenancy.md](../../docs/multi-tenancy.md).

## Modes

| Mode | When | Namespace | What is rendered |
|------|------|-----------|------------------|
| **Landing zone** | `tier: dedicated` (default), or `landingZone: true` (the `shared` pool tenant) | `tenant-<name>` (or `tenant.namespace`, e.g. `shared-services`) | Everything below |
| **Pooled tenant** | `tier: shared` (e.g. `initech`) | `shared-services` (owned by the `shared` release) | Kong consumer + rate limit + JWT credential, endpoints ConfigMap, tenant ExternalSecrets, optional data provisioning. Object names are prefixed `tenant-<name>-` |

## What the chart creates

| Area | Objects | Notes |
|------|---------|-------|
| Namespace | `Namespace` | Labels `istio-injection`, `pod-security.kubernetes.io/enforce=restricted`, `platform.example.com/tenant`, `platform.example.com/tier`; annotations with the Keycloak realm, OIDC issuer, API host, Vault path. `Prune=false,Delete=false` while `tenant.protectNamespace` |
| Quotas | `ResourceQuota` `tenant-quota`, `tenant-denied-priority-classes`, optional `tenant-apps-high-pods`; `LimitRange` `tenant-limits` | Requests CPU/memory, pods, PVCs, storage, LB = 0, NodePort = 0, object counts, `longhorn-db` forbidden, platform PriorityClasses forbidden |
| RBAC | `RoleBinding`s `tenant-admins` / `tenant-developers` / `tenant-viewers` → ClusterRoles `admin` / `edit` / `view`; `Role` + `RoleBinding` `tenant-delivery` | Subjects are Keycloak OIDC groups with `rbac.groupPrefix` (default `oidc:`) |
| Network | `NetworkPolicy` `default-deny-all`, `allow-dns`, `allow-same-namespace`, `allow-ingress-from-platform`, `allow-egress-to-platform` | Ingress from kong, istio-internal, istio-system, monitoring, observability. Egress to data-postgres/redis/rabbitmq/kafka, integration, observability, istio-system, istio-egress |
| Mesh | `PeerAuthentication` `default` (STRICT), `Sidecar` `default` (egress scope + `REGISTRY_ONLY`), `AuthorizationPolicy` `allow-nothing` + `allow-tenant-and-gateways` | Metrics paths are allowed from `monitoring` |
| Secrets | `ServiceAccount` `vault-tenant-auth`, `SecretStore` `vault-tenant`, `ExternalSecret`s from `externalSecrets.secrets` | Vault role `tenant-<name>` may read only `secret/tenants/<name>/*` |
| Edge | `KongConsumer` `tenant-<name>`, `KongPlugin` `tenant-<name>-rate-limit`, JWT credential Secret (via ExternalSecret) | The Kong `jwt` plugin (`key_claim_name: iss`) maps the realm issuer to the consumer, which turns `limit_by: consumer` into per-tenant limits |
| PostgreSQL | per database: `ExternalSecret` `<tenant>-<db>-owner`, CNPG `Database` `<tenant>-<db>` (db/owner `<tenant>_<db>`); hook `Job`s `pg-roles-<tenant>` (Sync) and `pg-grants-<tenant>` (PostSync) | In `data-postgres`, cluster `pg-main` |
| RabbitMQ | `Vhost` `<tenant>`, per service `User`/`Permission` `<tenant>-<svc>`, DLX `Exchange`/`Queue`/`Binding`, `Policy` `quorum-dlx` | In `data-rabbitmq`, `rabbitmqClusterReference: rabbitmq`, quorum default queue type |
| Kafka | `KafkaTopic` `<tenant>.<topic>`, per service `KafkaUser` `<tenant>-<svc>` (SCRAM, prefix ACLs, quotas) | In `data-kafka`, label `strimzi.io/cluster: kafka` |
| Discovery | `ConfigMap` `tenant-platform-endpoints` | All well-known endpoints + tenant DB names, Redis db/prefix, vhost, topic prefix, realm/issuer |

PriorityClasses are cluster-wide and are **not** created here (see `docs/resilience.md`).

## Sync ordering (Argo CD)

| Wave | Objects |
|------|---------|
| -10 | Namespace |
| 0 | everything else in the tenant namespace, ExternalSecrets in the data namespaces |
| 1 | `pg-roles-<tenant>` Sync hook Job, RabbitMQ `User`/`Exchange`/`Queue`, `KafkaUser` |
| 2 | CNPG `Database`, RabbitMQ `Permission`/`Binding`/`Policy` |
| PostSync | `pg-grants-<tenant>` Job (revokes `CONNECT`/`TEMPORARY` on each tenant database from `PUBLIC`) |

## Vault layout (seed before the first sync)

KV v2 mount `secret`, ClusterSecretStore `vault-backend`, per-tenant SecretStore `vault-tenant`:

| Path | Keys | Consumed by |
|------|------|-------------|
| `secret/tenants/<tenant>/<service>` | `DB_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`, `KAFKA_PASSWORD`, app secrets | the `<service>-<version>` releases (all keys, envFrom) **and** this chart (role/user passwords) - one source of truth |
| `secret/tenants/<tenant>/common` | anything shared by the tenant's workloads | ExternalSecret `tenant-common-secrets` |
| `secret/tenants/<tenant>/keycloak` | `realm_public_key` (PEM) | Kong JWT credential |

Vault Kubernetes auth role `tenant-<tenant>`: bound to SA `vault-tenant-auth` in `tenant-<tenant>`, policy
`path "secret/data/tenants/<tenant>/*" { capabilities = ["read"] }`.

## Prerequisites owned by other components

- Argo CD AppProject `tenants` allows cluster-scoped `Namespace` and destinations `tenant-*`, `shared-services`,
  `data-postgres`, `data-rabbitmq`, `data-kafka`.
- `Cluster` `pg-main` with `enableSuperuserAccess: true` (secret `pg-main-superuser`) for `roleManagement: job`,
  or managed roles declared in the Cluster for `roleManagement: managed`. The `data-postgres` network policy must
  admit the hook Job pods (label `app.kubernetes.io/name: pg-tenant-roles|pg-tenant-grants`).
- Kafka listeners with `scram-sha-512` authentication and `authorization: simple` (otherwise ACLs are not enforced).
- Istio CNI (PSA `restricted` forbids the `istio-init` container), Kong sidecar-injected (STRICT mTLS).
- Strimzi 1.x serves only `kafka.strimzi.io/v1`; set `data.kafka.apiVersion: kafka.strimzi.io/v1beta2` on Strimzi 0.x.

## Examples

```bash
helm template tenant-acme charts/tenant -f charts/tenant/ci/dedicated-values.yaml
helm template tenant-initech charts/tenant -f charts/tenant/ci/pooled-values.yaml
helm template tenant-shared charts/tenant -f charts/tenant/ci/pool-landing-zone-values.yaml
```

## Values

See the fully commented [values.yaml](values.yaml); [values.schema.json](values.schema.json) validates it
(tenant name pattern, tier enum, quotas, data options).
