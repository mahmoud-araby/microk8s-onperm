# ansible/ - MicroK8s HA provisioning, OS hardening, GitOps bootstrap, "ConfigMap Ansible"

This directory turns bare Ubuntu machines into a production MicroK8s HA cluster and hands it over to
Argo CD. After `site.yml`, **everything else in the platform is reconciled from `gitops/`**. Ansible
keeps four day-2 jobs: adding/removing nodes, rolling MicroK8s upgrades, dqlite backups, and
rendering tenant ConfigMaps ("ConfigMap Ansible").

Names, namespaces, node labels, storage classes and endpoints follow `docs/conventions.md` (binding).

```
controller (ansible-core >= 2.16, helm, python kubernetes)
   │ ssh
   ├── preflight ─ prepare-nodes (common + hardening) ─ cluster (microk8s + microk8s_ha) ─ addons
   │                                                                         │ kubeconfig -> inventories/<env>/.kubeconfig
   └── bootstrap-gitops (Argo CD HA, pinned chart) ── applies gitops/bootstrap/root-app.yaml
                                                         └── Argo CD installs MetalLB, Istio, Kong, Longhorn,
                                                             cert-manager, Vault, data services, observability,
                                                             tenants, applications
   day 2: configmaps.yml · vault-init.yml · upgrade.yml · backup.yml · add-node.yml · remove-node.yml
```

## Layout

```
ansible/
├── ansible.cfg                  defaults to the STAGING inventory (never production by accident)
├── requirements.yml             kubernetes.core, community.general, ansible.posix, community.crypto
├── filter_plugins/platform.py   ip_in_range / ip_ranges_overlap / ip_nth_in_cidr (preflight, no netaddr)
├── inventories/
│   ├── production/
│   │   ├── hosts.yml            3 masters + edge/platform/data/apps/observability pools
│   │   ├── files/               internal-ca.crt, platform-backup.pub.asc (public material only)
│   │   └── group_vars/
│   │       ├── all/             main, microk8s, network, os, registry, argocd, backup, configmaps,
│   │       │                    vault.yml.example (-> vault.yml, ansible-vault encrypted)
│   │       ├── microk8s_masters.yml, microk8s_workers.yml
│   │       └── edge.yml, platform.yml, data.yml, apps.yml, observability.yml   labels / taints / sizing
│   └── staging/                 same shape, smaller, masters schedulable, Argo CD non-HA
├── roles/
│   ├── common                   packages, chrony, swap off, kernel modules, sysctl, limits, THP,
│   │                            Longhorn prerequisites (iscsi, multipath, NVMe disk), ufw, journald, proxy
│   ├── hardening                sshd, auditd, unattended security updates, kernel/CIS bits, fail2ban
│   ├── microk8s                 pinned snap, refresh hold, launch config (CIDRs), kubelet args,
│   │                            containerd ulimits/proxy, Harbor mirrors (certs.d), API SANs
│   ├── microk8s_ha              add-node/join (masters serial, workers --worker), labels, taints,
│   │                            keepalived API VIP, HA verification
│   ├── microk8s_addons          dns, rbac, ha-cluster, metrics-server, helm3; HA CoreDNS; kubeconfig
│   ├── argocd_bootstrap         Argo CD HA via kubernetes.core.helm (pinned), repo secret, root app
│   ├── k8s_configmaps           "ConfigMap Ansible" (templates + layered vars -> ConfigMaps)
│   ├── vault_init               optional: init/unseal, KV v2 `secret`, k8s auth, ESO + tenant policies
│   ├── backup                   dqlite + PKI backup, systemd timer, GPG, off-node rsync, metrics
│   └── upgrade                  rolling, drained snap channel refresh with Longhorn health gate
├── configmaps/
│   ├── tenants/<tenant>.yml     tenant layer + deployed services (acme, globex, initech, shared)
│   └── services/<service>.yml   service catalogue defaults (orders, payments, catalog, web)
└── playbooks/                   site, preflight, prepare-nodes, cluster, addons, bootstrap-gitops,
                                 configmaps, vault-init, upgrade, backup, add-node, remove-node
```

## Sizing for ~1,000,000 users

Assumptions: 1M registered users, ~10% daily active, peak ~50k concurrent sessions, ~15-20k HTTP
req/s at the edge with a 3-5x fan-out to internal services, 30-day logs hot/warm, 15-day metrics.
Every pool is N+1 (one node can be drained for upgrades while peak load is still served) and spread
over 3 failure domains (`topology_zone` -> `topology.kubernetes.io/zone`).

| Pool (`workload-tier`) | Nodes | vCPU / RAM | Disk | Runs | Taint |
|------|------:|-----------|------|------|-------|
| masters (dqlite voters) | 3 | 8 / 32 GiB | 200 GB NVMe | kube-apiserver, dqlite, controller-manager, scheduler (dedicated in prod) | `node-role.kubernetes.io/control-plane:NoSchedule` (prod) |
| `edge` | 3 | 8 / 16 GiB, 2x 10/25 GbE | 100 GB | Kong (public VIP), Istio ingress/internal/egress gateways, MetalLB speakers | `workload-tier=edge:NoSchedule` |
| `platform` | 6 | 16 / 64 GiB | 200 GB | Argo CD (HA), Vault, Keycloak, Harbor, cert-manager, ESO, Kyverno, operators, Rollouts, KEDA, istiod | - |
| `data` | 6 | 32 / 128 GiB | 200 GB OS + 2-4 TB NVMe (`longhorn-db`) | CNPG Postgres, Redis+Sentinel, RabbitMQ, Kafka (KRaft), Micro Integrator | `workload-tier=data:NoSchedule` |
| `apps` | 12+ (HPA/KEDA headroom, grow to 24) | 16 / 64 GiB | 200 GB | tenant + pooled .NET / Java / Python services, frontends | - |
| `observability` | 8 | 16-32 / 64-128 GiB | 200 GB OS + 8-16 TB NVMe (see docs/capacity-planning.md) | Prometheus/Thanos, Alertmanager, Grafana, ECK Elasticsearch hot tier, Kibana, APM, OTel gateway | - |
| **Total** | **33** | ~530 vCPU / ~2.1 TiB | | | |

Scale-out rule of thumb: add `apps` nodes when requested CPU > 65% across the pool; add `data` nodes in
pairs; keep masters at 3 (5 only for > 150 nodes or multi-room clusters). kubelet `--max-pods` is 250 on
`apps` (110 elsewhere) with `--kube-reserved` / `--system-reserved` of 500m CPU + 1 GiB each.

## Prerequisites

Controller (CI runner or bastion):

```bash
python3 -m venv ~/.venvs/platform && . ~/.venvs/platform/bin/activate
pip install "ansible-core>=2.16,<2.20" "kubernetes>=29.0.0" PyYAML jsonpatch
cd ansible
ansible-galaxy collection install -r requirements.yml -p ./collections
# helm >= 3.14 on PATH (argocd_bootstrap), optional: kubectl
```

Nodes: Ubuntu Server 22.04/24.04 LTS, the `ansible` user with passwordless sudo and your SSH key,
static IPs, forward/reverse DNS or rely on the `/etc/hosts` block the `common` role manages, one
dedicated NVMe per `data`/`observability` node (`longhorn_disk_device` in `hosts.yml`).

Secrets:

```bash
cp inventories/production/group_vars/all/vault.yml.example inventories/production/group_vars/all/vault.yml
$EDITOR inventories/production/group_vars/all/vault.yml
ansible-vault encrypt --vault-id production@prompt inventories/production/group_vars/all/vault.yml
```

Only the encrypted `vault.yml` may ever be committed; `.gitignore` excludes kubeconfigs and Vault
init output.

## Usage

All commands run from `ansible/` (so `ansible.cfg` is used). `-i` defaults to staging.

```bash
# 0. Check everything before touching a node
ansible-playbook -i inventories/production/hosts.yml playbooks/preflight.yml

# 1. Full build (preflight -> OS -> MicroK8s HA -> addons -> Argo CD -> backups)
ansible-playbook -i inventories/production/hosts.yml playbooks/site.yml --vault-id production@prompt

# ... or step by step
ansible-playbook -i inventories/production/hosts.yml playbooks/prepare-nodes.yml
ansible-playbook -i inventories/production/hosts.yml playbooks/cluster.yml
ansible-playbook -i inventories/production/hosts.yml playbooks/addons.yml
ansible-playbook -i inventories/production/hosts.yml playbooks/bootstrap-gitops.yml --vault-id production@prompt
export KUBECONFIG=$PWD/inventories/production/.kubeconfig

# 2. After Argo CD has synced Vault (wave -10): one-time init/unseal/config
ansible-playbook -i inventories/production/hosts.yml playbooks/vault-init.yml \
  -e vault_init_enabled=true --vault-id production@prompt

# 3. Render tenant ConfigMaps (production: gitops mode -> commit the generated files in a PR)
ansible-playbook -i inventories/production/hosts.yml playbooks/configmaps.yml
```

Useful tags: `--tags sysctl`, `--tags firewall`, `--tags hardening`, `--tags microk8s_config`
(kubelet args / registry mirrors), `--tags labels` (node labels/taints), `--tags etc_hosts`,
`--tags keepalived`, `--tags argocd_root_app`, `--tags backup_now`.

| Playbook | Hosts | Purpose |
|----------|-------|---------|
| `site.yml` | all | preflight + prepare-nodes + cluster + addons + bootstrap-gitops + backup |
| `preflight.yml` | cluster + controller | OS/arch/kernel, vCPU/RAM/disk per pool, free ports, Longhorn disk, snap store reachability, odd master count, MetalLB ranges vs node IPs/VIP, registry CA validity, controller tooling |
| `prepare-nodes.yml` | `microk8s_cluster` | roles `common`, `hardening` |
| `cluster.yml` | cluster | install MicroK8s everywhere, join masters `serial: 1`, workers in batches (`microk8s_worker_join_batch`, default 3), verify HA |
| `addons.yml` | first master | addons, CoreDNS HA, kubeconfig -> `inventories/<env>/.kubeconfig` |
| `bootstrap-gitops.yml` | controller | Argo CD HA + repo secret + `gitops/bootstrap/root-app.yaml` |
| `configmaps.yml` | controller | "ConfigMap Ansible" (`apply` or `gitops`) |
| `vault-init.yml` | controller | guarded Vault init/unseal/config (`-e vault_init_enabled=true`) |
| `upgrade.yml` | cluster | backup, then masters one by one, then workers one by one |
| `backup.yml` | masters | backup timer; `-e backup_run_now=true`, `-e backup_fetch=true` |
| `add-node.yml` | `--limit <new>` | preflight, OS, MicroK8s, join, labels |
| `remove-node.yml` | first master | `-e node=<host>`: Longhorn eviction, drain, leave, remove-node |

## Nodes: labels, taints, HA

`microk8s_masters` join one at a time and become dqlite voters (`ha-cluster` is verified: >= 3
voters, every inventory node `Ready`). Worker pools join with `microk8s join <ip>:25000/<token>/<ca-hash> --worker`
using a fresh single-use token (`microk8s add-node --token ... --token-ttl 900`) per node; a node that
the first master already lists is skipped, so every run is idempotent.

Labels/taints come from the pool's group_vars (conventions "Nodes"):

| Group | Labels | Taints |
|-------|--------|--------|
| `edge` | `workload-tier=edge`, `node-role.kubernetes.io/edge` | `workload-tier=edge:NoSchedule` |
| `platform` | `workload-tier=platform`, `node-role.kubernetes.io/platform` | - |
| `data` | `workload-tier=data`, `node-role.kubernetes.io/data` | `workload-tier=data:NoSchedule` |
| `apps` | `workload-tier=apps`, `node-role.kubernetes.io/apps` | - |
| `observability` | `workload-tier=observability`, `node-role.kubernetes.io/observability` | - |
| `microk8s_masters` | `node-role.kubernetes.io/control-plane` | `node-role.kubernetes.io/control-plane:NoSchedule` when `microk8s_dedicated_masters` (prod) |

Every node also gets `topology.kubernetes.io/zone=<topology_zone>`. Stable API endpoint: keepalived
floats `microk8s_api_vip` (10.10.10.10) across the masters (VRRP unicast, TCP health check on
16443) and the VIP + `k8s-api.ops.example.local` are added to the API server certificate SANs; the
fetched kubeconfig points at `microk8s_api_endpoint`. Workers do not need the VIP (MicroK8s'
apiserver-proxy balances across all control-plane nodes).

MicroK8s specifics handled by the roles:

- **Pinned channel** (`microk8s_channel: 1.32/stable`) + `snap refresh --hold microk8s`; the role
  refuses to change the channel of an installed node outside `upgrade.yml`.
- **Launch configuration** (first install only): pod CIDR `10.1.0.0/16`, service CIDR `10.152.0.0/16`
  (the default /24 only has 254 ClusterIPs; the /16 still contains the CoreDNS IP `10.152.183.10`).
- **Harbor**: `certs.d/harbor.ops.example.local/hosts.toml` (+ internal CA) and pull-through
  proxy-cache mirrors for docker.io, quay.io, ghcr.io, registry.k8s.io, docker.elastic.co with
  fallback to upstream while Harbor itself is not deployed yet (`registry_mirror_fallback_to_upstream: false` for air-gapped).
- **Addons**: only `dns` (forwarding to on-prem resolvers), `rbac`, `ha-cluster`, `metrics-server`,
  `helm3`; `hostpath-storage` is disabled. MetalLB, ingress, Istio, cert-manager, storage and
  observability come from GitOps and are disabled here if found enabled.

## "ConfigMap Ansible" (`roles/k8s_configmaps`)

Renders application configuration files from Jinja2 templates and **layered variables**, wraps them in
ConfigMaps and delivers them in one of two modes.

```
layer 1 global       roles/k8s_configmaps/defaults/main.yml     k8s_configmaps_global + k8s_configmaps_endpoints
layer 2 environment  inventories/<env>/group_vars/all/configmaps.yml   k8s_configmaps_environment
layer 3 tenant       (implicit) <tenant>_ databases, <tenant>: Redis prefix, vhost, <tenant>. topics, issuer, API host
                     configmaps/tenants/<tenant>.yml   config + environments.<env>
layer 4 service      configmaps/services/<service>.yml config + environments.<env>   (catalogue defaults)
                     configmaps/tenants/<tenant>.yml   services[].config + services[].environments.<env>
                     -> deep merge (later wins, lists replaced) -> `cfg` in the templates
```

Templates by `language` (override per service with `templates: [{template: x.j2, key: file}]`;
custom templates may live in `configmaps/templates/`):

| language | key(s) in the ConfigMap | template |
|----------|------------------------|----------|
| `dotnet` | `appsettings.Production.json` (`appsettings.<Env>.json`) | `dotnet/appsettings.json.j2` - Kestrel, Npgsql/Redis connection strings (no passwords), RabbitMQ, Kafka, OIDC, OpenTelemetry, health paths |
| `java` | `application.yaml` | `java/application.yaml.j2` - Spring datasource/Hikari with `${DB_USER}`/`${DB_PASSWORD}`, Redis/Sentinel, RabbitMQ, Kafka, resource server JWT, actuator mapped to `/health/{live,ready,startup}` and `/metrics` |
| `python` | `.env`, `settings.json` | `python/app.env.j2` (pydantic-settings, `__` nested delimiter), `python/settings.json.j2` |
| `static` | `config.js` | `frontend/config.js.j2` - `window.__CONFIG__` (apiBaseUrl, authUrl, tenantId, features) |

Per tenant it also renders `tenant-settings` (tenant-level merged config: `settings.json` +
`TENANT_FEATURES_*`) and, for namespaces the tenant owns, `platform-endpoints` - every well-known
endpoint of `docs/conventions.md` as `PLATFORM_*` env keys (`PLATFORM_POSTGRES_HOST`,
`PLATFORM_KAFKA_BOOTSTRAP_SERVERS`, `PLATFORM_OTEL_GRPC_ENDPOINT`, `PLATFORM_VAULT_ADDR`, ...), usable with `envFrom`.

Naming (agreed with `charts/` and `gitops/`):

- `<objectPrefix><fullname>-files`, fullname = `<service>-<version>` (microservice) or `<name>` /
  `<name>-<tenant>` (frontend). `-files` because the charts already own `<fullname>-config`,
  `<fullname>-runtime-config` and `<fullname>-nginx`. Mount it with the charts' `extraVolumes` /
  `extraVolumeMounts`.
- `objectPrefix` = `tenant-<name>-` for **pooled** tenants (tier `shared`, e.g. `initech`) whose objects
  live in `shared-services`; empty for dedicated tenants and for the pool (`shared`).
- Labels: `app.kubernetes.io/{name,instance,part-of,component=config,managed-by=ansible}`, `version`,
  `platform.example.com/{tenant,language,generated-by=k8s-configmaps}`; annotation
  `platform.example.com/config-checksum` (sha256 of `data`).

Modes (`k8s_configmaps_mode`):

- **`gitops`** (production default) - writes `gitops/tenants/<tenant>/configmaps/generated-<configmap>.yaml`.
  That directory is a plain `directory` source of the tenant Application (`gitops/apps/applicationsets/tenants.yaml`),
  so: no `kustomization.yaml`, no `metadata.namespace` (the Application destination decides),
  sync-wave `5`, and **only `generated-*.yaml` files are ever written or pruned** - hand-written files
  such as `tenant-feature-flags.yaml` are never touched. Review and merge the diff like any other change
  (`-e k8s_configmaps_git_commit=true` commits locally; it never pushes).
- **`apply`** (staging default) - `kubernetes.core.k8s` apply into the tenant namespace (must exist),
  then for every ConfigMap whose content changed, patches `spec.template.metadata.annotations
  ["platform.example.com/config-checksum"]` on the Deployments / Argo Rollouts with label
  `app.kubernetes.io/instance=<fullname>` so the pods roll. Argo CD ignores that annotation
  (`resource.customizations.ignoreDifferences.all` in the Argo CD values). Stale generated ConfigMaps are pruned.

Safety: the role fails if any key that looks like a secret (`password`, `secret`, `token`, `apiKey`,
`connectionString`, ...) carries a literal value - secrets belong in Vault (`secret/tenants/<tenant>/<service>`)
and reach pods through External Secrets; use `${ENV_VAR}` placeholders. Rendered JSON/YAML is parsed
before it is written.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/configmaps.yml                      # all tenants, gitops
ansible-playbook -i inventories/production/hosts.yml playbooks/configmaps.yml -e '{"k8s_configmaps_only_tenants":["acme"]}'
ansible-playbook -i inventories/staging/hosts.yml playbooks/configmaps.yml -e '{"k8s_configmaps_only_services":["orders"]}'
```

Onboarding a tenant: add `configmaps/tenants/<name>.yml` (mirror `gitops/tenants/<name>/tenant.yaml`
and its `services/*.yaml`), add it to `platform_tenants` (and `platform_pooled_tenants` for tier
`shared`), run `configmaps.yml` and `vault-init.yml` (creates Vault role/policy `tenant-<name>`).

## Vault (`roles/vault_init`, optional)

Guarded by `vault_init_enabled`. Through the Kubernetes API (`k8s_exec` into `vault-N`) it:
initialises vault-0 (5 shares / threshold 3), writes the keys + root token to
`inventories/<env>/vault-init-<env>.yml` and immediately `ansible-vault encrypt`s it, unseals every pod
(raft `retry_join` from the Helm values; `vault_init_raft_manual_join` otherwise), enables KV v2 at
`secret/`, a stdout audit device, Kubernetes auth, the `external-secrets` policy/role used by the
`vault-backend` ClusterSecretStore, and per-tenant `tenant-<name>` policies/roles bound to SA
`vault-tenant-auth` (charts/tenant). Every write is preceded by a read (idempotent). Move the keys into
`vault.yml`, keep an offline copy, and revoke the root token once OIDC admin access exists.

## Upgrades

1. Bump `microk8s_channel` by **one** minor (`1.32/stable` -> `1.33/stable`) in
   `inventories/<env>/group_vars/all/microk8s.yml`; test in staging first.
2. `ansible-playbook -i inventories/production/hosts.yml playbooks/upgrade.yml`

The playbook takes a backup, then per node (`serial: 1`, `max_fail_percentage: 0`): checks all nodes
are Ready, drains (PDBs respected), `snap refresh microk8s --channel=...`, re-holds refresh, waits for
the node to be Ready on the new kubelet version, re-applies kubelet/containerd/registry config,
uncordons, waits until no Longhorn volume is `degraded`, pauses 60 s. Minor-version skips are refused.
Limit to a pool with `--limit data`.

## Backups and disaster recovery

`backup.yml` installs `microk8s-backup.timer` on every master: `microk8s dbctl backup` (full dqlite
datastore incl. Secrets) + a tarball of `certs/`, `credentials/`, `args/`, GPG-encrypted for
`backup_gpg_recipient`, SHA256SUMS, rsync over SSH (pinned host key) to `backup01`, local retention,
and `microk8s_backup_last_success` / `..._last_run_timestamp_seconds` via the node-exporter textfile
collector (alert when stale > 26 h). Application data is protected separately (CNPG barman backups,
Velero, Longhorn backups - GitOps).

Restore (total control-plane loss): build one master, restore the PKI tarball into
`/var/snap/microk8s/current/`, `microk8s dbctl restore <dqlite>.tar.gz`, start, then re-run
`cluster.yml` to re-join the other nodes and `bootstrap-gitops.yml` if Argo CD must be reinstalled.

## Conventions check / assumptions

- Node labels/taints, namespaces (`argocd`, `vault`, `external-secrets`, `tenant-<name>`, `shared-services`),
  endpoints, MetalLB pool names (`public-pool`, `internal-pool`), storage classes (Longhorn only;
  `hostpath-storage` disabled) and the Git URL/revision follow `docs/conventions.md`.
- `metallb_pools` in `network.yml` is the address plan the GitOps `IPAddressPool`s must match; Ansible
  validates it but does not deploy MetalLB.
- Argo CD chart `argo/argo-cd` is pinned to `10.9.2` (Argo CD v3.5), the same version the self-managed `gitops/bootstrap/argocd` Application uses, - verify the version exists in your
  mirror before the first run and bump deliberately. Release name `argocd` (resources `argocd-server`, ...).
  If Argo CD later manages itself from `gitops/`, reuse the same release name and values.
- Argo CD ServiceMonitors are left disabled at bootstrap (Prometheus Operator CRDs do not exist yet).
- Dedicated masters are tainted `node-role.kubernetes.io/control-plane:NoSchedule` in production:
  DaemonSets that must run there (node-exporter, Fluent Bit, Calico) need a matching toleration.
