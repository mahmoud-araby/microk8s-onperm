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
   optional, outside the cluster: vault-server.yml (external Vault HA) · minio-server.yml (external MinIO)
                                  storage-prep.yml (dedicated disks, also part of prepare-nodes / minio-server)
```

## Layout

```
ansible/
├── ansible.cfg                  defaults to the STAGING inventory (never production by accident)
├── requirements.yml             kubernetes.core, community.general, ansible.posix, community.crypto, community.hashi_vault
├── filter_plugins/platform.py   ip_in_range / ip_ranges_overlap / ip_nth_in_cidr (preflight, no netaddr)
├── inventories/
│   ├── production/
│   │   ├── hosts.yml            3 masters + edge/platform/data/apps/observability/storage pools,
│   │   │                        loadbalancers, vault_servers (3), minio_servers (4 x 4 drives)
│   │   ├── files/               internal-ca.crt, platform-backup.pub.asc (public material only)
│   │   └── group_vars/
│   │       ├── all/             main, microk8s, network, os, registry, argocd, backup, configmaps,
│   │       │                    secrets (secrets_backend + secret map, vault_deployment_mode),
│   │       │                    vault.yml.example (-> vault.yml, ansible-vault encrypted)
│   │       ├── microk8s_masters.yml, microk8s_workers.yml, loadbalancers.yml (+ all/loadbalancer.yml: mode, VIPs)
│   │       ├── vault_servers.yml, minio_servers.yml              external Vault / MinIO VMs
│   │       └── edge.yml, platform.yml, data.yml, apps.yml, observability.yml, storage.yml   labels / taints / sizing
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
│   ├── vault_init               optional: init/unseal, KV v2 `secret`, k8s auth, ESO + tenant policies,
│   │                            transit auto-unseal Secret + recovery-key init / seal migration (external|both)
│   ├── vault_server             optional external Vault HA on VMs: raft, TLS, hardened systemd, audit + logrotate,
│   │                            init/unseal, transit key `autounseal-k8s` + token, KV v2 + AppRole `ansible`
│   ├── minio_server             optional external distributed MinIO: built/pinned binaries, TLS, erasure coding,
│   │                            backup buckets (versioning, object lock, ILM), per-consumer users -> Vault
│   ├── storage_prep             guarded XFS prep: local-nvme (/mnt/local-nvme[/dataN]), MinIO drives (/mnt/diskN),
│   │                            kubelite RequiresMountsFor, NFS client; Longhorn disk via role common
│   ├── pki_cert                 helper: host key + CSR signed by the internal CA on the controller (or files)
│   ├── backup                   dqlite + PKI backup, systemd timer, GPG, off-node rsync and/or S3 (platform-dqlite), metrics
│   ├── loadbalancer             edge HAProxy + keepalived pair (group `loadbalancers`): L7 TLS / L4 PROXY v2 to
│   │                            Kong + Istio internal, always-L4 k8s API + Kafka, VRRP VIPs (docs/load-balancing.md)
│   └── upgrade                  rolling, drained snap channel refresh with Longhorn health gate
├── configmaps/
│   ├── tenants/<tenant>.yml     tenant layer + deployed services (acme, globex, initech, shared)
│   └── services/<service>.yml   service catalogue defaults (orders, payments, catalog, web)
└── playbooks/                   site, preflight, prepare-nodes, loadbalancers, vault-server, minio-server,
                                 storage-prep, cluster, addons, bootstrap-gitops, configmaps, vault-init,
                                 upgrade, backup, add-node, remove-node
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
| `observability` | 10 | 16-32 / 64-128 GiB | 200 GB OS + 2-16 TB NVMe (5 general, 3 ES hot, 2 ES warm; see docs/capacity-planning.md) | Prometheus/Thanos, Alertmanager, Grafana, ECK Elasticsearch hot tier, Kibana, APM, OTel gateway | - |
| `storage` | 4 | 16 / 64 GiB | 100 GB OS + 4x NVMe (`/mnt/local-nvme/data0..3`, `local-nvme` / `local-nvme-minio`) | in-cluster MinIO tenant `minio` (erasure coding over 16 drives) | `workload-tier=storage:NoSchedule` |
| **Total** | **37** | ~595 vCPU / ~2.35 TiB | | | |

Outside the cluster (optional, own failure domain): `vault_servers` 3 x 2 vCPU / 4 GiB / 50 GB SSD
(raft), `minio_servers` 4 x 8 vCPU / 32 GiB with 4 data drives each (backup target, EC:4, usable
~75% of raw), `loadbalancers` 2 x HAProxy/keepalived.

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
# secrets_backend=hashicorp_vault / minio_server credential push: pip install "hvac>=2.1.0"
# minio_server_binary_source=build (default): git + Go (version of the MinIO tag's go.mod) on the controller
```

Nodes: Ubuntu Server 22.04/24.04 LTS, the `ansible` user with passwordless sudo and your SSH key,
static IPs, forward/reverse DNS or rely on the `/etc/hosts` block the `common` role manages, one
dedicated NVMe per `data`/`observability` node (`longhorn_disk_device` in `hosts.yml`), 4 dedicated
NVMe per `storage` node (`local_nvme_devices`), 4 data drives per `minio_servers` VM (`minio_drives`).

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

# Optional infrastructure outside the cluster (also imported by site.yml; no-op for empty groups)
ansible-playbook -i inventories/production/hosts.yml playbooks/vault-server.yml -e vault_server_init=true --vault-id production@prompt
ansible-playbook -i inventories/production/hosts.yml playbooks/minio-server.yml --vault-id production@prompt
ansible-playbook -i inventories/production/hosts.yml playbooks/storage-prep.yml --limit storage
```

Useful tags: `--tags sysctl`, `--tags firewall`, `--tags hardening`, `--tags microk8s_config`
(kubelet args / registry mirrors), `--tags labels` (node labels/taints), `--tags etc_hosts`,
`--tags keepalived`, `--tags argocd_root_app`, `--tags backup_now`, `--tags lb_certs` / `lb_haproxy` (loadbalancers.yml).

| Playbook | Hosts | Purpose |
|----------|-------|---------|
| `site.yml` | all | preflight + prepare-nodes + loadbalancers + vault-server + minio-server + cluster + addons + bootstrap-gitops + backup |
| `preflight.yml` | cluster + controller | OS/arch/kernel, vCPU/RAM/disk per pool, free ports, Longhorn disk, snap store reachability, odd master count, MetalLB ranges vs node IPs/VIP, registry CA validity, controller tooling |
| `prepare-nodes.yml` | `microk8s_cluster` | roles `common`, `storage_prep`, `hardening` |
| `storage-prep.yml` | `microk8s_cluster`, `minio_servers` | role `storage_prep` alone (e.g. after adding a disk); `-e storage_prep_force=true` to wipe |
| `vault-server.yml` | `vault_servers` (`serial: 1`), then the first one | roles `hardening`, `vault_server`; `-e vault_server_init=true` once; then transit/KV/AppRole config |
| `minio-server.yml` | `minio_servers` | roles `hardening`, `storage_prep`, `minio_server` (buckets, ILM, identities, credentials) |
| `loadbalancers.yml` | `loadbalancers` (`serial: 1`) | roles `hardening`, `loadbalancer`: HAProxy (`haproxy -c` validated, hitless reload) + keepalived VIPs; `--tags lb_certs` re-syncs TLS certs (docs/load-balancing.md) |
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
| `storage` | `workload-tier=storage`, `node-role.kubernetes.io/storage` | `workload-tier=storage:NoSchedule` |
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

With `vault_deployment_mode: external | both` (transit auto-unseal, see below) the role first creates
Secret `vault/vault-transit-token` (key `token`), initialises with **recovery** keys
(`vault_recovery_keys`, 5 / 3) instead of unseal keys, and never unseals (the pods auto-unseal).
An already initialised Shamir Vault is migrated with `-e vault_init_seal_migrate=true` (each pod in
migration mode gets `vault operator unseal -migrate` with the old keys).

## Secrets backend (`group_vars/all/secrets.yml`)

`secrets_backend: ansible_vault` (default) keeps every secret in `group_vars/all/vault.yml`.
`secrets_backend: hashicorp_vault` reads them from the **external** Vault with
`community.hashi_vault.vault_kv2_get` lookups (AppRole `ansible`, `pip install hvac`):

```bash
export VAULT_ADDR=https://vault-ext.example.local:8200            # default when unset
export VAULT_ROLE_ID=<role_id printed by vault-server.yml>
export VAULT_SECRET_ID=$(vault write -f -field=secret_id auth/approle/role/ansible/secret-id)
ansible-playbook -i inventories/production/hosts.yml playbooks/site.yml -e secrets_backend=hashicorp_vault
```

`secrets.yml` maps every secret-bearing role input to its source. Lookups are lazy: a secret is only
fetched when a play uses it.

| Role input | ansible-vault variable | External Vault (KV v2 `secret/`) |
|------------|------------------------|----------------------------------|
| `argocd_repo_username` / `_password` / `_ssh_private_key`, `argocd_oidc_client_secret`, `argocd_admin_password_bcrypt` | `vault_argocd_*` | `ansible/<env>/argocd`: `repo_username`, `repo_password`, `repo_ssh_private_key`, `oidc_client_secret`, `admin_password_bcrypt` |
| `registry_username` / `registry_password` (reserved, no consumer yet) | `vault_registry_*` | `ansible/<env>/registry`: `username`, `password` |
| `vault_init_unseal_keys`, `vault_init_root_token` | `vault_unseal_keys`, `vault_root_token` | `ansible/<env>/vault-in-cluster`: `unseal_keys`, `root_token` |
| `vault_init_transit_token` | `vault_ext_transit_token` | `platform/vault-transit-token`: `token` (written by `vault_server`) |
| `backup_remote_ssh_private_key` | `vault_backup_ssh_private_key` | `ansible/<env>/backup`: `ssh_private_key` |
| `backup_s3_access_key` / `_secret_key` | `vault_backup_s3_*` | `platform/dqlite-s3`: `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` (written by `minio_server`) |
| `lb_keepalived_auth_pass`, `lb_stats_password` | `vault_lb_*` | `ansible/<env>/loadbalancer`: `keepalived_auth_pass`, `stats_password` |
| `minio_server_root_user` / `_password` | `vault_minio_external_root_*` | `platform/minio-external`: `root-user`, `root-password` |

These always stay in ansible-vault, because HashiCorp Vault can't hold the secrets it needs to start:
`vault_ext_unseal_keys`, `vault_ext_root_token` and `vault_internal_ca_key_passphrase`.

## External Vault and Vault deployment modes (`roles/vault_server`, optional)

`vault_deployment_mode` (`group_vars/all/secrets.yml`, docs/conventions.md "External Vault (optional)"):

| Mode | In-cluster Vault (`vault` ns) | External Vault (`vault_servers`) |
|------|------------------------------|----------------------------------|
| `in-cluster` (default) | Shamir, unsealed by `vault-init.yml` | not used |
| `external` | seal `transit` -> auto-unseal via key `autounseal-k8s`; apps keep using it through ESO `vault-backend` | root of trust (transit), Ansible secrets source |
| `both` | as `external` | also an ESO backend (ClusterSecretStore on `vault-ext`) for secrets that must survive the loss of the cluster |

`vault-server.yml` (hosts `vault_servers`, `serial: 1`) does the following:

- Installs the pinned `vault` package from the HashiCorp apt repo and holds it.
- Builds a raft cluster with `retry_join` to every peer over TLS. The certificate comes from the internal CA
  via `pki_cert`, with SANs `vault-ext.example.local`, the node FQDN, the node IP and 127.0.0.1.
- Enables listener telemetry for Prometheus (`/v1/sys/metrics?format=prometheus`, unauthenticated) and the UI.
- Runs Vault under a sandboxed systemd unit (`ProtectSystem=strict`, only `CAP_IPC_LOCK`, ...).
- Configures ufw: 8200 from the node, admin and LB networks, 8201 between peers only.
- Turns swap off.
- Enables the file audit device `/var/log/vault/audit.log`, rotated by logrotate (SIGHUP).

A restart seals a node, so the play handles nodes one at a time and unseals each one before moving to the next.

- **Init:** only with `-e vault_server_init=true`, and only if Vault is not initialised yet. The output goes to
  `inventories/<env>/vault-ext-init-<env>.yml`, which is ansible-vault encrypted immediately. With
  `vault_server_init_output: print` it is printed once instead. Move the values to `vault_ext_unseal_keys` /
  `vault_ext_root_token`. The external Vault stays Shamir-sealed: after a reboot, re-run the playbook or unseal by hand.
- **Configuration** (first node, needs the root token):
  - autopilot dead-server cleanup and the audit device
  - `transit/` with key `autounseal-k8s` and policy `autounseal-k8s`
  - a periodic orphan token for the seal. It is reused while valid and stored at
    `secret/platform/vault-transit-token` and in the encrypted `vault-ext-transit-token-<env>.yml`.
  - KV v2 at `secret/`
  - AppRole `ansible`: its policy reads `secret/ansible/*` and writes `secret/platform/*`; its `secret_id` is
    bound to the admin CIDRs. The playbook prints the role_id; issue one secret_id per controller.
- **Endpoint:** `https://vault-ext.example.local:8200` is DNS round-robin over the nodes or a TCP VIP on the
  `loadbalancers` pair (health check `GET /v1/sys/health`). Standby nodes forward requests to the leader.

To enable transit auto-unseal of the in-cluster Vault:

1. Run `vault-server.yml`; it creates the key and the token. Set `vault_deployment_mode: external` and either
   `vault_ext_transit_token` or `secrets_backend: hashicorp_vault`.
2. In `gitops/platform/core/vault/values.yaml`, uncomment `seal "transit"` and `extraSecretEnvironmentVars`
   (`VAULT_TOKEN` from Secret `vault-transit-token`). The external Vault certificate must be signed by the same
   CA as `internal-ca`, which is the case with `pki_cert` in internal_ca mode.
3. Run `vault-init.yml -e vault_init_enabled=true`. It creates the Secret before the pods restart and initialises
   new clusters with recovery keys. For an existing cluster, delete the pods one at a time (OnDelete), then re-run
   with `-e vault_init_seal_migrate=true`.

ExternalSecret alternative: instead of Ansible writing Secret `vault-transit-token`, create a ClusterSecretStore
(for example `vault-external`, AppRole or token auth against `https://vault-ext.example.local:8200`) and an
ExternalSecret in namespace `vault` that reads `secret/platform/vault-transit-token` into key `token`. Set
`vault_init_create_transit_secret: false`. This store must not depend on the in-cluster Vault.

## External MinIO (`roles/minio_server`, optional)

The external MinIO is the backup target outside the cluster failure domain (docs/conventions.md "Object storage",
docs/storage.md "Backups"). `minio-server.yml` runs three roles on `minio_servers`: `hardening`, `storage_prep`
(XFS on `minio_drives`, mounted at `/mnt/disk1..N` with `nofail`) and `minio_server`.

- **Distribution:** check MinIO's current licensing and distribution before production.
  - The community edition (AGPLv3) has been in maintenance mode and source-only since late 2025: the dl.min.io
    archive binaries and the public images are gone. AIStor is the commercial edition.
  - `minio_server_binary_source: build` (default) builds `minio` `RELEASE.2025-10-15T17-29-55Z` and `mc`
    `RELEASE.2025-08-13T08-35-41Z` from the git tags on the controller (`minio_server_build_host`, needs git and
    Go). The binaries are cached in `ansible/.cache/minio-artifacts/` and their sha256 is printed.
  - `minio_server_binary_source: url` downloads from an internal mirror with a pinned sha256.
  - Ceph RGW, SeaweedFS and Garage are S3-compatible alternatives. Consumers only see the endpoint and per-bucket
    credentials.
- **Server setup:**
  - user `minio-user`
  - `/etc/default/minio` with `MINIO_VOLUMES=https://minio-{1...4}.storage.example.local:9000/mnt/disk{1...4}/minio`:
    4 nodes x 4 drives in one 16-drive erasure set with `EC:4`. A single node uses `/mnt/disk{1...N}/minio`.
  - TLS files in `/etc/minio/certs` (`public.crt`, `private.key`, `CAs/`)
  - a sandboxed systemd unit with `RequiresMountsFor` on every drive
  - Prometheus metrics with `MINIO_PROMETHEUS_AUTH_TYPE=jwt` or `public`. For jwt, a bearer token is generated once
    with `mc admin prometheus generate` and stored at `secret/platform/minio-external-metrics`.
  - ufw: 9000 from the node, admin and LB networks and from peers; console port 9001 from the admin networks only.
- **Endpoint:** the role writes `minio-1..4.storage.example.local` to `/etc/hosts` on the MinIO nodes; add them to
  DNS too. **`minio.storage.example.local:9000` must be a round-robin DNS name over all nodes, or a VIP on the
  `loadbalancers` pair** (TCP passthrough, health check `GET /minio/health/live`). It is set as `MINIO_SERVER_URL`
  and is a SAN on every node certificate. Every consumer uses it.
- **Buckets and identities:** created on the first node with `mc`; the credentials exist only in the `mc` process
  environment. Bucket names match what the GitOps manifests use (`minio_server_buckets`, `minio_server_consumers`):

| Bucket | Versioning | Object lock (default retention) | ILM | User -> Vault (KV v2) keys |
|--------|-----------|-------------------------------|-----|----------------------------|
| `pg-backups` | yes | GOVERNANCE 30 d | noncurrent 35 d | `svc-postgres-backup` -> `platform/postgres-backup`: `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `ca.crt` |
| `velero-backups` | yes | - (BSL uses `checksumAlgorithm: ""`) | noncurrent 30 d | `svc-velero` -> `platform/velero`: `s3-access-key`, `s3-secret-key` |
| `thanos-metrics` | no (compactor rewrites) | - | - | `svc-thanos` -> `platform/thanos`: `access-key`, `secret-key` |
| `es-snapshots` | yes | - | noncurrent 7 d | `svc-elastic-snapshots` -> `platform/elastic-snapshots`: `access-key`, `secret-key` |
| `longhorn-backups` | yes | - | noncurrent 14 d | `svc-longhorn` -> `platform/longhorn`: `s3-access-key`, `s3-secret-key`, `s3-endpoint`, `s3-ca-cert` |
| `platform-dqlite` | yes | GOVERNANCE 7 d | expire 30 d, noncurrent 7 d | `svc-dqlite` -> `platform/dqlite-s3`: `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `endpoint` |
| `harbor-registry` | no | - | - | `svc-harbor` -> `platform/harbor-s3`: `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `endpoint` |

- **Policies:** each user gets one policy limited to its own bucket (list, get, put, delete, multipart; no admin).
  Object lock can only be enabled when a bucket is created; the role warns about buckets that already exist without it.
- **Credentials:** generated once, then re-read on every run, so re-runs don't rotate them. Where they go:
  - With `secrets_backend: hashicorp_vault` they are merged into the existing Vault secrets with
    `community.hashi_vault.vault_kv2_write`. `minio_server_credentials_vault_url` must be the Vault that ESO reads:
    the external one in mode `both`, otherwise point it at the in-cluster Vault.
  - Otherwise they are written to `inventories/<env>/minio-external-credentials-<env>.yml` (ansible-vault encrypted)
    for manual seeding with `vault kv patch -mount=secret <path> ...`.
- **dqlite:** set `backup_s3_enabled: true` in role `backup` to upload the GPG-encrypted archives to
  `platform-dqlite`. The upload uses `curl --aws-sigv4`, plus Content-MD5 for the object-lock bucket. Credentials
  come from `vault_backup_s3_*` or `platform/dqlite-s3`.

## Storage preparation (`roles/storage_prep`)

`storage_prep` is part of `prepare-nodes.yml` (cluster nodes) and `minio-server.yml` (MinIO VMs);
`storage-prep.yml` runs it on its own.

| Input | Result | Used by |
|-------|--------|---------|
| `local_nvme_devices` (list, `storage` pool: 4 NVMe) | XFS, `/mnt/local-nvme/data0..3`, fstab by UUID, `noatime,nofail` | local-path provisioner, classes `local-nvme` / `local-nvme-minio` (in-cluster MinIO tenant) |
| `local_nvme_device` (single disk, any other pool, set per host) | XFS, `/mnt/local-nvme` | class `local-nvme` (scratch, caches) |
| `minio_drives` (`minio_servers`, optionally cluster nodes) | XFS labelled `MINIODISK<n>`, `/mnt/disk1..N` | external MinIO |
| `longhorn_disk_device` | ext4 `/var/lib/longhorn` - role `common` (re-used, not duplicated) | Longhorn |
| cluster nodes | `nfs-common` | csi-driver-nfs, class `nfs-rwx` |

- **Never wipes data by accident:**
  - A device is formatted only if `blkid -p` finds no signature, or finds the wanted filesystem already.
  - A foreign filesystem, a partition table or partitions make the role fail unless `-e storage_prep_force=true`.
  - A device that is mounted elsewhere, or holds `/`, is never touched.
  - A device may be listed only once across `longhorn_disk_device`, `local_nvme_device(s)` and `minio_drives`.
- **Mounts:** all mounts use `nofail`, so a dead disk does not block boot. Instead,
  `snap.microk8s.daemon-kubelite.service` gets a drop-in with `RequiresMountsFor=/mnt/local-nvme[/dataN]`, and
  `minio.service` requires its drives, so nothing writes volume data onto the root filesystem. The drop-in takes
  effect at the next kubelite (re)start.
- **NFS (`nfs-rwx`):** setting up the NFS server is out of scope. Its export `nfs.storage.example.local:/exports/k8s`
  must be exported to the node networks (`platform_node_cidrs`) with `rw,sync,no_subtree_check,no_root_squash`,
  because csi-driver-nfs creates the per-PVC directories as root.

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
`backup_gpg_recipient`, SHA256SUMS, rsync over SSH (pinned host key) to `backup01` and/or (`backup_s3_enabled`)
an S3 upload to the external MinIO bucket `platform-dqlite`, local retention,
and `microk8s_backup_last_success` / `..._last_run_timestamp_seconds` via the node-exporter textfile
collector (alert when stale > 26 h). Application data is protected separately (CNPG barman backups,
Velero, Longhorn backups - GitOps).

Restore (total control-plane loss): build one master, restore the PKI tarball into
`/var/snap/microk8s/current/`, `microk8s dbctl restore <dqlite>.tar.gz`, start, then re-run
`cluster.yml` to re-join the other nodes and `bootstrap-gitops.yml` if Argo CD must be reinstalled.

## Conventions check / assumptions

- Node labels/taints, namespaces (`argocd`, `vault`, `external-secrets`, `tenant-<name>`, `shared-services`),
  endpoints, MetalLB pool names (`public-pool`, `internal-pool`), storage classes (Longhorn, plus `local-nvme` on disks prepared by `storage_prep`, `nfs-rwx`, `minio-s3` from GitOps;
  `hostpath-storage` disabled) and the Git URL/revision follow `docs/conventions.md`.
- `metallb_pools` in `network.yml` is the address plan the GitOps `IPAddressPool`s must match; Ansible
  validates it but does not deploy MetalLB.
- Argo CD chart `argo/argo-cd` is pinned to `10.9.2` (Argo CD v3.5), the same version the self-managed `gitops/bootstrap/argocd` Application uses, - verify the version exists in your
  mirror before the first run and bump deliberately. Release name `argocd` (resources `argocd-server`, ...).
  If Argo CD later manages itself from `gitops/`, reuse the same release name and values.
- Argo CD ServiceMonitors are left disabled at bootstrap (Prometheus Operator CRDs do not exist yet).
- Dedicated masters are tainted `node-role.kubernetes.io/control-plane:NoSchedule` in production:
  DaemonSets that must run there (node-exporter, Fluent Bit, Calico) need a matching toleration.
