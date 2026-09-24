# Platform core (`gitops/platform/core`)

The networking, security and delivery layer of the MicroK8s HA platform. Every sub-directory is one
component. It holds an `application.yaml` (an Argo CD `Application` in project `core`, namespace `argocd`),
plus a `values.yaml` for the Helm chart and/or a `manifests/` directory. The category app-of-apps
`gitops/bootstrap/apps/platform-core.yaml` picks up every `*/application.yaml`. The binding naming contract
is in [`docs/conventions.md`](../../../docs/conventions.md).

## Components

| Dir | Application | Namespace | Chart (pinned) | Wave | Notes |
|-----|-------------|-----------|----------------|------|-------|
| `cluster-defaults` | cluster-defaults | – | manifests | -20 | Core namespaces (PSS + injection labels), PriorityClasses `platform-critical`, `apps-high`, `apps-default` (global default), `batch-low` |
| `metallb` | metallb | metallb-system | metallb/metallb 0.16.1 | -15 | `public-pool`, `internal-pool` (L2 on edge nodes), BGP example |
| `cert-manager` | cert-manager | cert-manager | jetstack/cert-manager v1.21.2 | -15 | ClusterIssuers `internal-ca`, `selfsigned-bootstrap`, `letsencrypt-prod`, `letsencrypt-staging`; wildcard certs for istio-internal |
| `longhorn` | longhorn | longhorn-system | longhorn/longhorn 1.12.1 | -15 | StorageClasses `longhorn` (default, 3 replicas) and `longhorn-db` (1 replica, strict-local); RecurringJobs |
| `local-path-provisioner` | local-path-provisioner | local-path-storage | rancher/local-path-provisioner v0.0.37 (git) | -15 | StorageClasses `local-nvme` and `local-nvme-minio` on disks mounted by Ansible `storage_prep` |
| `csi-driver-nfs` | csi-driver-nfs | csi-nfs | csi-driver-nfs 4.13.4 | -15 | StorageClass `nfs-rwx` (RWX) against `nfs.storage.example.local:/exports/k8s` |
| `csi-s3` | csi-s3 | csi-s3 | manifests (k8s-csi-s3 0.43.7) | -10 | Driver `ru.yandex.s3.csi` (geesefs), StorageClass `minio-s3`; mounts MinIO buckets into pods |
| `minio-operator` | minio-operator | minio-operator | minio/operator 7.1.1 | -10 | MinIO operator (trusts the internal CA) |
| `minio` | minio | minio | minio/tenant 7.1.1 | -5 | Tenant `minio`: 4 servers × 4 NVMe on `storage` nodes, EC, TLS, console on `minio-console.ops.example.local`. See [docs/storage.md](../../../docs/storage.md) |
| `istio-base` | istio-base | istio-system | istio/base 1.30.5 | -10 | CRDs |
| `istio-cni` | istio-cni | istio-system | istio/cni 1.30.5 | -10 | No privileged init containers, MicroK8s CNI paths |
| `istiod` | istiod | istio-system | istio/istiod 1.30.5 | -10 | 3–6 replicas, PDB, JSON access logs, OTel tracing, `REGISTRY_ONLY` |
| `vault` | vault | vault | hashicorp/vault 0.34.1 | -10 | Raft HA ×3, TLS (internal-ca), UI, ServiceMonitor, auto-unseal placeholders |
| `external-secrets` | external-secrets | external-secrets | external-secrets 2.11.0 | -10 | ClusterSecretStore `vault-backend`, PushSecret example |
| `kyverno` | kyverno | kyverno | kyverno/kyverno 3.9.1 | -10 | 3 admission replicas; ClusterPolicies |
| `argo-rollouts` | argo-rollouts | argo-rollouts | argo/argo-rollouts 2.43.2 | -10 | 2 controllers, dashboard, notifications |
| `keda` | keda | keda | kedacore/keda 2.21.0 | -10 | Operator ×2, metrics server ×2, ServiceMonitors |
| `istio-ingress` | istio-ingress | istio-ingress | istio/gateway 1.30.5 | -5 | Public gateway (`public-pool`), release `istio-ingressgateway` |
| `istio-internal` | istio-internal | istio-internal | istio/gateway 1.30.5 | -5 | Internal gateway (`internal-pool`), Gateway `internal-gateway`, istiod exposure for VMs |
| `istio-egress` | istio-egress | istio-egress | istio/gateway 1.30.5 | -5 | Egress gateway on edge nodes |
| `istio` | istio-mesh-config | istio-system | manifests | -5 | PeerAuthentication STRICT, Telemetry (10 %), default Sidecar, ops VirtualServices |
| `hybrid` | hybrid-services | istio-egress / legacy-vms | manifests | -5 | VM mesh expansion, SaaS egress with TLS origination, cloud Kafka. See [hybrid/README.md](hybrid/README.md) |
| `kong` | kong | kong | kong/ingress 0.24.0 | -5 | DB-less, 3–20 proxies on edge nodes, global plugins |
| `keycloak` | keycloak | keycloak | codecentric/keycloakx 7.3.2 | -5 | Keycloak 26 ×3, DNS_PING, CNPG `pg-main` db `keycloak`, realm import |
| `harbor` | harbor | harbor | goharbor/harbor 1.19.2 | -5 | External CNPG + Redis Sentinel, Trivy, `harbor.ops.example.local` |
| `velero` | velero | velero | vmware-tanzu/velero 12.2.0 | -5 | Kopia node-agent, MinIO BSL, hourly tenant / daily and weekly cluster schedules |
| (bootstrap) | argocd | argocd | argo/argo-cd 10.9.2 | -25 | Self-managed, in `gitops/bootstrap/argocd` |

Every chart version carries the comment `# pin: verify latest before upgrade`.

## Application pattern

* The chart comes from its upstream repo, and `valueFiles: [$values/gitops/platform/core/<c>/values.yaml]`
  is read from this repo through a `ref: values` source. A third source applies `gitops/platform/core/<c>/manifests`.
* `syncPolicy`: automated `prune` + `selfHeal`. `CreateNamespace=true`. `ServerSideApply=true` for charts
  with many CRDs. `SkipDryRunOnMissingResource=true` because the CRs in `manifests/` need CRDs from the same
  or earlier apps. Retries back off from 10s up to 5m, 10 attempts.
* Webhook `caBundle`s, which cert-manager, Istio and KEDA inject at runtime, are ignored with
  `RespectIgnoreDifferences=true`.
* Inside an app, the CRs in `manifests/` carry `argocd.argoproj.io/sync-wave: "1"` or later, so they are
  applied after the chart's CRDs and webhooks are healthy. Secrets and certificates that pods mount carry
  wave `-1`.

## Sync waves and bootstrap order

| Wave | Content |
|------|---------|
| -30 | `projects` (AppProjects) |
| -25 | Argo CD (self-managed) |
| -20 | `platform-core` category, `cluster-defaults` |
| -15 | MetalLB, Longhorn, cert-manager (+ ClusterIssuers), local-path provisioner, NFS CSI |
| -10 | Istio base / CNI / istiod, Vault, ESO (+ `vault-backend`), Kyverno, Rollouts, KEDA, MinIO operator, CSI S3 |
| -5 | Gateways (Istio ingress, internal, egress, Kong), mesh config, hybrid, Keycloak, Harbor, Velero, MinIO tenant |
| 0 / 5 | `platform-data` / `platform-observability` |
| 10 / 20 | Tenants / applications (ApplicationSets) |

Waves order when things are **created**. They do not gate on readiness across categories: Argo CD has no
health check for `Application` resources, and no custom one is configured on purpose. Core depends on data
(Keycloak and Harbor use CNPG and Redis), and data depends on core (Vault/ESO, Longhorn, Istio). A
readiness gate between categories would deadlock. Dependencies converge through sync retries,
`SkipDryRunOnMissingResource`, dependency-aware pods (`dbchecker` in Keycloak, optional secret mounts in
Argo CD) and Kubernetes' own reconciliation.

Two deviations from the global wave table:

* **ClusterIssuers** are applied by the `cert-manager` app (wave -15, in-app wave 1–3) instead of wave -5,
  because Vault (wave -10) already needs a certificate from `internal-ca`.
* **ClusterSecretStore `vault-backend`** is applied by the `external-secrets` app (wave -10, in-app wave 1).
  It becomes `Ready` once Vault has been initialised (see below).

### First install (performed by Ansible, `make gitops`)

1. `helm install argocd argo/argo-cd --version 10.9.2 -n argocd -f gitops/bootstrap/argocd/values.yaml`
2. `kubectl apply -f gitops/bootstrap/root-app.yaml`. Everything else comes from Git.
3. When `vault-0` is Running: run `vault operator init` (store the recovery keys in escrow or HSM), unseal
   (or configure auto-unseal), and `vault operator raft join` on vault-1 and vault-2. Then enable
   `kv-v2` at `secret/`, the Kubernetes auth role `external-secrets` (policy in
   `external-secrets/manifests/clustersecretstore.yaml`) and OIDC auth for humans.
4. Seed the Vault paths listed below. ExternalSecrets refresh within `refreshInterval`, or force a refresh with
   `kubectl annotate es --all force-sync=$(date +%s)`.

### Vault paths used by core

| Path | Keys | Consumer |
|------|------|----------|
| `secret/platform/argocd` | `oidc-client-secret`, `slack-token`, `smtp-username`, `smtp-password` | Argo CD |
| `secret/platform/argo-rollouts` | `slack-token` | Rollouts notifications |
| `secret/platform/keycloak` | `db-password` (shared with data/postgres), `admin-username`, `admin-password`, `client-{argocd,grafana,harbor,vault,kiali}` | Keycloak |
| `secret/platform/harbor` | `admin-password`, `secret-key` (16 chars), `db-password` (shared with data/postgres) | Harbor |
| `secret/platform/minio` | `root-user`, `root-password` (alphanumeric) | In-cluster MinIO tenant, bootstrap/provisioning Jobs |
| `secret/platform/csi-s3` | `access-key`, `secret-key` | CSI S3 driver (`minio-s3` dynamic volumes in bucket `platform-pvc`) |
| `secret/platform/redis` | `password` (owned by data/redis) | Harbor |
| `secret/platform/kong` | `keycloak-<tenant>-rsa-public-key`, `partner-erp-jwt-secret` | Kong consumers |
| `secret/platform/longhorn` | `s3-access-key`, `s3-secret-key`, `s3-endpoint`, `s3-ca-cert` | Longhorn backups |
| `secret/platform/velero` | `s3-access-key`, `s3-secret-key` | Velero |
| `secret/platform/internal-ca-public` | `ca.crt` (written by PushSecret) | Argo CD, VMs, CI |

## Cross-component contracts

* **Kong and the Istio mesh.** Kong proxies are injected. Inbound traffic bypasses Envoy; outbound goes
  through the sidecar, which provides mTLS, retries, outlier detection, and the Rollouts canary weights
  on the service VirtualService. Upstream Services must carry `ingress.kubernetes.io/service-upstream: "true"`
  so Kong targets the Service rather than pod IPs. Kong's own Sidecar (`kong/manifests/sidecar.yaml`) sees
  `*/*`. Every other namespace gets the restrictive default Sidecar from `istio/manifests/sidecar-default.yaml`.
* **Egress.** The mesh runs `REGISTRY_ONLY`. External destinations need a ServiceEntry, which lives in
  `hybrid/` or `gitops/platform/data`. Tenants cannot create one (the `apps` project blacklists ServiceEntry).
* **mTLS STRICT.** Clients outside the mesh cannot reach meshed pods' application ports. Prometheus should
  scrape the merged metrics port `:15020/stats/prometheus` (`enablePrometheusMerge`) or run with an Istio
  sidecar and certificate output.
* **Ops UIs** on `*.ops.example.local` are VirtualServices bound to `istio-internal/internal-gateway`.
  Argo CD, Rollouts, Vault, Harbor and Keycloak are defined in `istio/manifests/ops-virtualservices.yaml`.
  Grafana, Kibana and Kiali are defined in `gitops/platform/observability`, and RabbitMQ in `gitops/platform/data`.
  Define one VirtualService per host only.
* **Keycloak hostnames.** Tenant realms are served at `https://keycloak.example.com/realms/<tenant>`
  (public, through Kong; `/admin` is not exposed). The `platform` realm issuer is
  `https://keycloak.ops.example.local/realms/platform` (realm `frontendUrl`), and so is the admin console.
  Tenant tokens carry the claim `tenant`: hard-coded in tenant realms, a user attribute in `platform`.
* **Harbor Redis DB indexes 5–8** are reserved (core, jobservice, registry, trivy).
* **PriorityClass `data-critical`** is owned by `gitops/platform/data/data-common`, not by `cluster-defaults`.
* **Namespace `shared-services`** (with its quota and limit range) is owned by the tenant landing zone
  `gitops/tenants/shared` (charts/tenant), not by `cluster-defaults`.

## Upgrades

General procedure, one component per merge request:

1. Read the upstream release notes for **every** version between the current pin and the target
   (breaking value renames, CRD changes, Kubernetes version support).
2. Bump `targetRevision` (and image tags pinned in values, such as the Velero AWS plugin or Keycloak) and
   render locally: `helm template <rel> <repo>/<chart> --version <v> -f values.yaml`. Diff the result
   against the live manifests with `argocd app diff <app>`.
3. Merge to `main` during a change window. Argo CD syncs automatically. Watch `argocd app get <app>` and the
   Grafana dashboards.
4. Roll back by reverting the commit. Rolling back a CRD needs care: check the upstream downgrade notes.

Component specifics:

| Component | Notes |
|-----------|-------|
| Istio | Upgrade at most one minor version at a time, in this order: `istio-base` → `istio-cni` → `istiod` → gateways → restart workloads so they pick up new sidecars (`kubectl rollout restart`, one tenant namespace at a time). For zero-risk upgrades use revisions: install `istiod-<rev>` alongside and move namespaces with `istio.io/rev`. |
| Argo CD | Bump `gitops/bootstrap/argocd/application.yaml`; Argo CD upgrades itself. Check the RBAC and resource-tracking changes of each major version. Keep `configs.params` in sync with the ApplicationSet progressive-sync requirement. |
| Longhorn | Upgrade one minor version at a time and only while every volume is healthy. `preUpgradeChecker.jobEnabled` stays `false` under Argo CD, so run `longhornctl check preflight` manually. Engine upgrades are automatic (`concurrentAutomaticEngineUpgradePerNodeLimit: 1`). |
| Vault | The StatefulSet uses `OnDelete`. After the sync, delete the standby pods one at a time, then the active pod (`vault operator step-down` first). Check `vault operator raft list-peers` between steps. Take a raft snapshot before upgrading. |
| cert-manager | CRDs are part of the chart (`crds.enabled`, `keep`). Check `cmctl check api` after the upgrade. |
| Kyverno | Check for deprecated policy fields (`validationFailureAction` → `failureAction`, and so on). Upgrade in Audit mode first if the policy schema changed. |
| Keycloak | The keycloakx chart pins a Keycloak major version. Take a CNPG backup first, because database migrations are one-way. Upgrade in place with a rolling StatefulSet update; realms are not re-imported. |
| Harbor | Take a database backup first; Harbor migrates its schema on startup. Match the chart and app versions from the upstream matrix. |
| Kong | Check the KIC and Kong Gateway compatibility matrix. DB-less config is rebuilt from CRDs, so no migrations are needed. |
| Velero | Keep `velero-plugin-for-aws` compatible with the Velero minor version (plugin v1.14.x works with Velero 1.18). |
| MetalLB | CRD API versions (`metallb.io/v1beta1` / `v1beta2`) are stable. To switch between L2 and BGP, see `metallb/manifests/bgp-example.yaml`. |

## Disaster recovery

* **Velero:** hourly backups of `tenant-*` (resources + Kopia volumes, 72h), daily full cluster (30 days),
  weekly full cluster including volumes (90 days, data namespaces excluded because they use native backups).
* **Longhorn:** hourly snapshots, daily and weekly backups to S3/NFS. `longhorn-db` volumes get 6-hourly snapshots only.
* **Harbor:** a second Harbor at the DR site is a replication endpoint. On the primary, configure
  *Registries → New endpoint* (the DR Harbor, using a robot account) and *Replications → push-based*, with
  event-based triggers for `platform/*` and tenant projects plus a nightly full sync. CI can fail over to
  the DR registry by switching `image.registry`. Kyverno's registry policy must then allow the DR hostname.
* **Vault:** raft snapshots via a CronJob or Vault Enterprise automated snapshots to object storage; recovery
  keys in escrow.
* **Argo CD:** stateless. Git is the source of truth, and `argocd admin export` can be kept for app history.
