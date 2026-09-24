# gitops/apps - service catalogue and release flow

```
gitops/apps/
├── applicationsets/            synced by the bootstrap Application "tenants-and-apps" (wave 10)
│   ├── tenants.yaml            gitops/tenants/*/tenant.yaml           -> tenant-<t>            (charts/tenant)
│   └── services.yaml           gitops/tenants/*/services/*.yaml       -> <t>-<svc>-<version>   (charts/microservice|frontend)
├── orders/    values.yaml  values-v1.yaml  values-v2.yaml     .NET     postgres + redis + kafka + rabbitmq
├── payments/  values.yaml  values-v1.yaml  values-v2.yaml     Java     postgres + rabbitmq + kafka, KEDA on queue depth
├── catalog/   values.yaml  values-v1.yaml  values-v2.yaml     Python   postgres + redis + kafka
└── web/       values.yaml  values-v1.yaml  values-v2.yaml     SPA      charts/frontend
```

- `<service>/values.yaml` - service-wide defaults for every version and tenant: language, image repository,
  dependencies, migrations, resources sized for ~1M users, HPA/KEDA ranges, Kong/Istio policies, canary steps.
- `<service>/values-<version>.yaml` - `image.tag` (the only line CI edits) + version-specific config and
  feature flags. One file per **major** API version.

## Values precedence for a release

```
charts/<chart>/values.yaml
  < gitops/apps/<svc>/values.yaml
  < gitops/apps/<svc>/values-<version>.yaml
  < gitops/tenants/<t>/values-<chart>.yaml
  < helm.valuesObject  (tenant wiring from the ApplicationSet + descriptor imageTag / replicas / values)
```

Values that differ per tenant (topic prefix, vhost, DB name, ...) are referenced from the catalogue with
`tpl`, e.g. `KAFKA_ORDERS_TOPIC: "{{ .Values.dependencies.kafka.topicPrefix }}orders-events"`, so one
catalogue file serves every tenant.

## Release flow (new image of an existing major version)

```
merge to main (services/payments-java)
  └─ CI: build, test, scan (Trivy), sign (cosign), push harbor.ops.example.local/platform/payments:1.12.1
      └─ CI commits  gitops/apps/payments/values-v1.yaml  image.tag: "1.12.1"
          └─ Argo CD: every <t>-payments-v1 Application is OutOfSync
              └─ ApplicationSet RollingSync
                   step 1  ring=canary   (globex-payments-v1)            -> must become Healthy
                   step 2  ring=early    (acme-payments-v1, 50% at once) -> Healthy
                   step 3  ring=general  (shared-payments-v1, 25% at once)
                  └─ inside each release: Argo Rollouts canary
                       5% -> pause -> 20% -> ... -> 100%, Istio weighted routing (VirtualService weights,
                       ignored by Argo CD via ignoreDifferences + RespectIgnoreDifferences=true)
                       AnalysisTemplate (Prometheus): success rate >= 99.5%, p95 < 800 ms
                       failure -> automatic abort + rollback to the stable ReplicaSet; the Application turns
                       Degraded and RollingSync stops before the next ring
```

Tenants that pin `imageTag` in their descriptor (e.g. acme payments during a change freeze) are not affected.

Operational commands: `kubectl argo rollouts get rollout payments-v1 -n tenant-globex --watch`,
`kubectl argo rollouts promote|abort payments-v1 -n tenant-globex`, or the Rollouts dashboard at
`rollouts.ops.example.local`.

## Multiple versions side by side

A major version is its own Helm release `<service>-<version>` with its own Deployment/Rollout, Service,
VirtualService, HPA/KEDA, PDB, ServiceMonitor, ConfigMap and Vault secret. In `tenant-acme`:

| Release | Kong route | Image | Database |
|---------|------------|-------|----------|
| `orders-v1` | `acme.api.example.com/orders/v1/*` | `values-v1.yaml` 1.8.x | `acme_orders` |
| `orders-v2` | `acme.api.example.com/orders/v2/*` (+ `X-API-Version: v2` header route) | `values-v2.yaml` 2.4.x | `acme_orders` |

Both majors share the tenant's database (schema changes must be backward compatible - expand/contract
migrations, v2 migrations never break v1), the vhost and the topic prefix, while consumer groups are
per version (`<tenant>.orders-v1`, `<tenant>.orders-v2`). The pooled releases in `shared-services` follow the
same pattern on `api.example.com`.

Frontends are not versioned by path: to run `web-v2` next to `web-v1` for one tenant, set
`values.name: web-v2` and a separate host (e.g. `beta.acme.app.example.com`) in the descriptor.

## Adding a new major version

1. Add `gitops/apps/<svc>/values-v3.yaml` (tag + config). Nothing is deployed yet.
2. Opt in a canary-ring tenant: `gitops/tenants/globex/services/<svc>-v3.yaml` (`ring: canary`).
3. Widen: add the descriptor to other tenants and to `shared/` (pooled tenants get it through the pool).
4. CI starts bumping `values-v3.yaml` from the new release branch.

## Sunsetting a version

1. Announce: set deprecation headers in `values-v1.yaml` config (`Deprecation`, `Sunset` RFC 8594) and alert
   on remaining traffic (`sum by (tenant) (rate(kong_http_requests_total{route=~".*orders-v1.*"}[1d]))`).
2. Per tenant, when its traffic is zero: delete `gitops/tenants/<t>/services/orders-v1.yaml`. The Application
   and every object of the release are deleted (Kong route returns 404; data is untouched).
3. When no tenant references it: delete `gitops/apps/orders/values-v1.yaml` and stop the CI job. The
   ApplicationSet uses `ignoreMissingValueFiles: false`, so a descriptor still pointing at a removed version
   fails loudly instead of deploying a default image.

## Autoscaling at 1M users

| Service | Mechanism | Min / max (default) | Signal |
|---------|-----------|---------------------|--------|
| orders | HPA | 3 / 60 (v1: 2 / 20) | CPU 65% |
| payments | KEDA | 3 / 80 | RabbitMQ `payments.order-created` depth (200 msgs/replica) + CPU 70% |
| catalog | HPA | 3 / 80 | CPU 60% |
| web | HPA | 3 / 30 | CPU 70% |

Pooled releases get higher ceilings in `gitops/tenants/shared/services/*.yaml`. The ceilings are the
noisy-neighbour guard rail together with the tenant ResourceQuota: a tenant can never scale past its quota.

## Prerequisites owned by other components

- AppProjects `tenants` and `apps` (gitops/bootstrap/projects), with destinations `tenant-*`, `shared-services`
  (both) and `data-postgres`, `data-rabbitmq`, `data-kafka` + cluster-scoped `Namespace` (tenants).
- ApplicationSet controller flag `applicationsetcontroller.enable.progressive.syncs: "true"` for RollingSync.
- Argo CD resource tracking by annotation (default in Argo CD 3.x) so `app.kubernetes.io/instance` stays the
  Helm release name required by the conventions.
