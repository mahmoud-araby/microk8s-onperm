# charts/tenant

Tenant landing zone: one Helm release per tenant, rendered by the ApplicationSet
`gitops/apps/applicationsets/tenants.yaml` from `gitops/tenants/<tenant>/tenant.yaml` (sync wave 10).
The values contract lives in [docs/chart-interfaces.md](../../docs/chart-interfaces.md#chartstenant).
The tenancy model is described in [docs/multi-tenancy.md](../../docs/multi-tenancy.md).

## Modes

| Mode | When | Namespace | What is rendered |
|------|------|-----------|------------------|
| **Landing zone** | `tier: dedicated` (default), or `landingZone: true` (the `shared` pool tenant) | `tenant-<name>` (or `tenant.namespace`, e.g. `shared-services`) | Everything below |
| **Pooled tenant** | `tier: shared` (e.g. `initech`) | `shared-services` (owned by the `shared` release) | Kong consumer + rate limit + JWT credential, endpoints ConfigMap, tenant ExternalSecrets, optional data provisioning (incl. object storage: Secret `tenant-<name>-s3-credentials`, claims `tenant-<name>-<volume>`). Object names are prefixed `tenant-<name>-` |

## What the chart creates

| Area | Objects | Notes |
|------|---------|-------|
| Namespace | `Namespace` | Labels `istio-injection`, `pod-security.kubernetes.io/enforce=restricted`, `platform.example.com/tenant`, `platform.example.com/tier`; annotations with the Keycloak realm, OIDC issuer, API host, Vault path. `Prune=false,Delete=false` while `tenant.protectNamespace` |
| Quotas | `ResourceQuota` `tenant-quota`, `tenant-denied-priority-classes`, optional `tenant-apps-high-pods`; `LimitRange` `tenant-limits` | Requests CPU/memory, `requests/limits.ephemeral-storage`, pods, PVCs, storage, LB = 0, NodePort = 0, object counts, `longhorn-db` forbidden, platform PriorityClasses forbidden. LimitRange defaults `ephemeral-storage` (64Mi request / 1Gi limit, max 20Gi) so containers without a value (istio-proxy, startup containers) pass the quota |
| RBAC | `RoleBinding`s `tenant-admins` / `tenant-developers` / `tenant-viewers` → ClusterRoles `admin` / `edit` / `view`; `Role` + `RoleBinding` `tenant-delivery` | Subjects are Keycloak OIDC groups with `rbac.groupPrefix` (default `oidc:`) |
| Network | `NetworkPolicy` `default-deny-all`, `allow-dns`, `allow-same-namespace`, `allow-ingress-from-platform`, `allow-egress-to-platform`, `allow-egress-to-minio` (object storage) | Ingress from kong, istio-internal, istio-system, monitoring, observability. Egress to data-postgres/redis/rabbitmq/kafka, integration, observability, istio-system, istio-egress; `minio` on TCP 443 + 9000 (pod port) when object storage is enabled (the Istio `Sidecar` then also lists `minio/*`) |
| Mesh | `PeerAuthentication` `default` (STRICT), `Sidecar` `default` (egress scope + `REGISTRY_ONLY`), `AuthorizationPolicy` `allow-nothing` + `allow-tenant-and-gateways` | Metrics paths are allowed from `monitoring` |
| Secrets | `ServiceAccount` `vault-tenant-auth`, `SecretStore` `vault-tenant`, `ExternalSecret`s from `externalSecrets.secrets` | Vault role `tenant-<name>` may read only `secret/tenants/<name>/*` |
| Edge | `KongConsumer` `tenant-<name>`, `KongPlugin` `tenant-<name>-rate-limit`, JWT credential Secret (via ExternalSecret) | The Kong `jwt` plugin (`key_claim_name: iss`) maps the realm issuer to the consumer, which turns `limit_by: consumer` into per-tenant limits |
| PostgreSQL | per database: `ExternalSecret` `<tenant>-<db>-owner`, CNPG `Database` `<tenant>-<db>` (db/owner `<tenant>_<db>`); hook `Job`s `pg-roles-<tenant>` (Sync) and `pg-grants-<tenant>` (PostSync) | In `data-postgres`, cluster `pg-main` |
| RabbitMQ | `Vhost` `<tenant>`, per service `User`/`Permission` `<tenant>-<svc>`, DLX `Exchange`/`Queue`/`Binding`, `Policy` `quorum-dlx` | In `data-rabbitmq`, `rabbitmqClusterReference: rabbitmq`, quorum default queue type |
| Kafka | `KafkaTopic` `<tenant>.<topic>`, per service `KafkaUser` `<tenant>-<svc>` (SCRAM, prefix ACLs, quotas) | In `data-kafka`, label `strimzi.io/cluster: kafka` |
| Object storage | `ExternalSecret`s `tenant-s3-credentials` + `internal-ca-bundle` (tenant ns), `tenant-<t>-s3-user` (ns `minio`); Sync hook `Job` `minio-provision-<t>` (ns `minio`); per static volume `PersistentVolume` `<t>-<name>` + `PersistentVolumeClaim` `<name>` | `data.objectStorage.enabled`. Buckets `<t>-<name>`, MinIO user = `S3_ACCESS_KEY` (convention `<t>`), policy `<t>-rw` - see below |
| Discovery | `ConfigMap` `tenant-platform-endpoints` | All well-known endpoints + tenant DB names, Redis db/prefix, vhost, topic prefix, realm/issuer, `S3_ENDPOINT`/`S3_REGION`/`S3_BUCKET_PREFIX`/`S3_BUCKETS` |

PriorityClasses are cluster-wide and are **not** created here (see `docs/resilience.md`).

## Sync ordering (Argo CD)

| Wave | Objects |
|------|---------|
| -10 | Namespace |
| 0 | everything else in the tenant namespace, ExternalSecrets in the data namespaces |
| 1 | `pg-roles-<tenant>` and `minio-provision-<tenant>` Sync hook Jobs, RabbitMQ `User`/`Exchange`/`Queue`, `KafkaUser` |
| 2 | CNPG `Database`, RabbitMQ `Permission`/`Binding`/`Policy` |
| PostSync | `pg-grants-<tenant>` Job (revokes `CONNECT`/`TEMPORARY` on each tenant database from `PUBLIC`) |

## Vault layout (seed before the first sync)

KV v2 mount `secret`, ClusterSecretStore `vault-backend`, per-tenant SecretStore `vault-tenant`:

| Path | Keys | Consumed by |
|------|------|-------------|
| `secret/tenants/<tenant>/<service>` | `DB_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`, `KAFKA_PASSWORD`, app secrets | the `<service>-<version>` releases (all keys, envFrom) **and** this chart (role/user passwords) - one source of truth |
| `secret/tenants/<tenant>/common` | anything shared by the tenant's workloads | ExternalSecret `tenant-common-secrets` |
| `secret/tenants/<tenant>/keycloak` | `realm_public_key` (PEM) | Kong JWT credential |
| `secret/tenants/<tenant>/storage` | `S3_ACCESS_KEY` (= MinIO user name, use `<tenant>`), `S3_SECRET_KEY` (random, 40 chars) | Secret `tenant-s3-credentials` (apps + csi-s3) and the provisioning Job (creates/updates the MinIO user) |
| `secret/platform/internal-ca-public` | `ca.crt` | Secret `internal-ca-bundle` (TLS verification of MinIO) |

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
- Object storage (`gitops/platform/core/minio`, `csi-s3`): Secret `minio-provisioner-credentials` in `minio` (keys
  `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`; **not** created by this chart), Secret `minio-tls` (key `ca.crt`), a
  `minio` NetworkPolicy admitting the Job pods (`app.kubernetes.io/name: minio-tenant-provisioner`) and tenant
  namespaces on port 9000, the csi-s3 driver `ru.yandex.s3.csi`. AppProject `tenants` must allow destination `minio`
  (ExternalSecret + Job), cluster-scoped `PersistentVolume` and namespaced `PersistentVolumeClaim`.

## Object storage (MinIO)

`data.objectStorage` provisions a tenant's slice of the in-cluster MinIO (`https://minio.minio.svc.cluster.local`):

1. **Credentials** - ExternalSecret `tenant-s3-credentials` (pooled: `tenant-<t>-s3-credentials` in `shared-services`)
   from Vault `tenants/<t>/storage` with keys for the apps (`S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_ENDPOINT`,
   `S3_REGION`) **and** for the csi-s3 driver (`accessKeyID`, `secretAccessKey`, `endpoint`, `region` - the keys read by
   `pkg/s3/client.go` of yandex-cloud/k8s-csi-s3). `charts/microservice`/`charts/frontend` default to this Secret name
   (the `shared` pool landing zone renders the unprefixed name in `shared-services`).
2. **Provisioning** - Sync hook Job `minio-provision-<t>` in `minio` (`mc`, root credentials from
   `minio-provisioner-credentials`, CA from `minio-tls`), idempotent on every sync: `mc mb --ignore-existing`
   (+ `--with-lock`), `mc version enable`, `mc quota set/clear`, policy `<t>-rw` (bucket-level list/location +
   object get/put/delete/multipart on `arn:aws:s3:::<t>-*`, or only the listed buckets with `policyScope: buckets`),
   `mc admin user add` (re-applies the Vault secret = rotation) and `mc admin policy attach`. Pod: non-root, read-only
   root fs, no SA token, no sidecar. Buckets are never deleted by the chart.
3. **Static bucket volumes** - per `volumes[]` entry a PV `<t>-<name>` (`csi.driver: ru.yandex.s3.csi`,
   `volumeHandle: <bucket>/<prefix>`, `volumeAttributes: {mounter: geesefs, options: "--no-systemd ..."}`,
   `nodeStageSecretRef` + `nodePublishSecretRef` → the tenant Secret, `claimRef` → `<ns>/<name>`, reclaim `Retain`)
   and a PVC `<name>` with `storageClassName: ""` + `volumeName` (no dynamic provisioning, binds only to that PV).
   The driver mounts in `NodeStageVolume`, so the stage secret is required. `readOnly` volumes are `ReadOnlyMany`, get
   `-o ro`, and should be mounted read-only by the workload (csi-s3 does not enforce `readOnly` itself).
   A released PV (claim deleted) does not re-bind automatically: clear `spec.claimRef.uid` or delete the PV (data stays).
4. **Network/mesh** - `allow-egress-to-minio` NetworkPolicy and `minio/*` in the Istio `Sidecar` egress hosts.

Caveats: the policy's `<t>-*` prefix also matches buckets of a tenant named `<t>-<something>`; use
`policyScope: buckets` when such tenant ids coexist. Tenant ids and bucket names must be DNS-compatible (3-63 chars).

```yaml
data:
  objectStorage:
    enabled: true
    buckets: [files, {name: exports, versioning: true, quota: 200GiB}]
    quota: 1TiB
    volumes:
      - {name: product-images, bucket: acme-files, prefix: images/, size: 100Gi, readOnly: true}
```

## Examples

```bash
helm template tenant-acme charts/tenant -f charts/tenant/ci/dedicated-values.yaml
helm template tenant-initech charts/tenant -f charts/tenant/ci/pooled-values.yaml
helm template tenant-shared charts/tenant -f charts/tenant/ci/pool-landing-zone-values.yaml
helm template tenant-acme charts/tenant -f charts/tenant/ci/object-storage-values.yaml
```

## Values

See the fully commented [values.yaml](values.yaml); [values.schema.json](values.schema.json) validates it
(tenant name pattern, tier enum, quotas, data options).
