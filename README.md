# MicroK8s On-Prem Enterprise Microservices Platform

A GitOps platform for hosting **.NET, Java and Python microservices** and **frontends** on an
on-prem **MicroK8s HA** cluster, sized for **~1,000,000 users**, with **multi-tenancy** and
**multiple live versions of the same service**.

## What's included

| Area | Components |
|------|-----------|
| Cluster provisioning | Ansible: OS hardening & tuning, MicroK8s HA (dqlite), node pools/taints, upgrades, dqlite backups, **ConfigMap generation** (`k8s_configmaps` role) |
| GitOps | Argo CD (HA) app-of-apps, AppProjects, ApplicationSets for tenants × services × versions |
| Gateways | **Kong** external API gateway (public), **Istio internal gateway** (private), Istio egress gateway |
| Service mesh | Istio: mTLS, **retries, timeouts, circuit breakers**, outlier detection, authorization |
| Delivery | **Argo Rollouts canary** with Prometheus analysis, side-by-side versions (`orders-v1`, `orders-v2`) |
| Hybrid | ServiceEntry/WorkloadEntry for legacy VMs, egress gateway to cloud APIs, Kafka external listener, **WSO2 Micro Integrator** |
| Data | **PostgreSQL** (CloudNativePG, sync replication, PgBouncer, PITR), **Redis** + Sentinel, **RabbitMQ** (quorum queues, federation), **Kafka** (Strimzi KRaft, HTTP bridge = Kafka-compatible endpoints, MirrorMaker2 replication), optional SQL Server |
| Observability | **Prometheus** + Thanos + Alertmanager + Grafana, **Elasticsearch/Kibana logging** (Fluent Bit), **APM** (OpenTelemetry → Elastic APM), Kiali, blackbox probes, SLO burn-rate alerts |
| Security | Vault + External Secrets, cert-manager, Keycloak (OIDC, realm per tenant), Kyverno policies, Harbor + Trivy, cosign |
| Scaling & availability | HPA, **KEDA** (queue/lag-based), PDBs, topology spread, PriorityClasses, Velero backups, Longhorn storage, MetalLB |
| Workloads | Generic Helm charts (`microservice`, `frontend`, `tenant`) with **startup (init) containers, sidecars**, probes, security contexts |
| Reference apps | `orders` (.NET 8), `payments` (Java 21 / Spring Boot), `catalog` (Python / FastAPI), `web` (React SPA) |
| CI | GitHub Actions: build, test, SAST, Trivy, SBOM, cosign, push to Harbor, GitOps image-tag bump |

## Repository layout

```
ansible/                      Provisioning: inventories, roles, playbooks
charts/
  microservice/               Generic chart for .NET / Java / Python services
  frontend/                   SPA hosting (nginx) with runtime config per tenant
  tenant/                     Tenant landing zone (namespace, quotas, RBAC, netpol, data provisioning)
gitops/
  bootstrap/                  Root app-of-apps, AppProjects, Argo CD self-management
  platform/core/              Istio, Kong, MetalLB, cert-manager, Longhorn, Vault, ESO, Keycloak, Kyverno, Rollouts, KEDA, Velero, Harbor
  platform/data/              Postgres, Redis, RabbitMQ, Kafka, Micro Integrator
  platform/observability/     Prometheus stack, Thanos, ECK, Fluent Bit, OpenTelemetry, Kiali, dashboards, alerts
  apps/                       Service catalogue (values per service & version) + ApplicationSets
  tenants/                    One folder per tenant: tenant.yaml + pinned service versions
services/                     Reference microservices + docker-compose for local dev
docs/                         Architecture, conventions, capacity, resilience, multi-tenancy, runbooks
.github/                      CI workflows, dependabot, CODEOWNERS
```

## Quick start

```bash
# 1. Describe your hosts
cp -r ansible/inventories/staging ansible/inventories/mysite   # edit hosts.yml + group_vars
ansible-vault create ansible/inventories/mysite/group_vars/all/vault.yml   # see vault.yml.example

# 2. Provision the cluster and bootstrap GitOps
make deps
make preflight ENV=mysite
make site ENV=mysite            # nodes -> MicroK8s HA -> addons -> Argo CD -> root app

# 3. Watch the platform converge (sync waves: infra -> data -> observability -> tenants -> apps)
make status ENV=mysite
```

Before the first sync, replace placeholders:

- `example.com` / `example.local` domains (`grep -r example.com gitops charts`)
- MetalLB address ranges (`ansible/inventories/*/group_vars/all/*.yml`, `gitops/platform/core/metallb`)
- S3/MinIO endpoints for backups (CNPG, Velero, Elasticsearch snapshots, Thanos)
- Secrets in Vault under `secret/platform/*` and `secret/tenants/*` (see component READMEs)

## Onboarding a tenant

```bash
cp -r gitops/tenants/_template gitops/tenants/newco
# edit tenant.yaml (tier, quotas, data) and services/*.yaml (which service versions it runs)
make configmaps ENV=production     # optional: render tenant ConfigMaps via Ansible into gitops/tenants/newco/configmaps
git commit -am "onboard tenant newco" && git push   # ApplicationSets create everything
```

## Shipping a new version

- New **image** of an existing version → CI bumps `gitops/apps/<svc>/values-<version>.yaml` → Argo Rollouts canary per tenant.
- New **major version** → add `values-v3.yaml`, reference `<svc>-v3.yaml` from the tenants that opt in; v2 keeps running.

## Documentation

- [Architecture](docs/architecture.md)
- [Conventions (naming, endpoints, contracts)](docs/conventions.md)
- [Chart values interfaces](docs/chart-interfaces.md)
- [Capacity planning for 1M users](docs/capacity-planning.md)
- [Resilience: retries, timeouts, circuit breakers, startup & sidecar containers](docs/resilience.md)
- [Multi-tenancy & multiple versions](docs/multi-tenancy.md)
- [Runbooks](docs/runbooks/)
- Component READMEs in `ansible/`, `charts/*`, `gitops/**`, `services/`
