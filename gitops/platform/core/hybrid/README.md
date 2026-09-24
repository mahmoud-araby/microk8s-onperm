# Hybrid services

How workloads in the MicroK8s cluster reach systems that run outside it: legacy VMs in the datacenter,
SaaS APIs on the Internet, and managed cloud services. Everything goes through Istio. Every destination
is registered explicitly, because the mesh runs with `outboundTrafficPolicy: REGISTRY_ONLY`.

| Case | Resources (`manifests/`) | Path |
|------|--------------------------|------|
| (a) Legacy SQL Server + ERP on VMs | `10-legacy-erp-vms.yaml`: WorkloadGroup, WorkloadEntry, Service, DestinationRule, VirtualService, AuthorizationPolicy (namespace `legacy-vms`) | pod sidecar → **mTLS** → VM sidecar (VM mesh expansion) |
| (b) External SaaS API | `20-saas-api-egress.yaml`: ServiceEntry, egress Gateway, DestinationRules, VirtualService, AuthorizationPolicy (namespace `istio-egress`) | app (HTTP) → sidecar → **mTLS** → egress gateway → **TLS origination** → SaaS |
| (c) Cloud-managed Kafka | `30-cloud-kafka.yaml`: ServiceEntry, egress Gateway (TLS passthrough), VirtualService, DestinationRule | client TLS/SASL_SSL end-to-end, routed by SNI through the egress gateway |

Data-tier ServiceEntries (external databases and brokers) live in `gitops/platform/data`. This directory
has the platform patterns and the examples.

## Network design: site-to-site VPN

```
             Datacenter / legacy VLANs                          Cloud (VPC/VNet)            Internet SaaS
  +--------------------------------------------+          +-----------------------+
  |  ERP app VMs 10.20.30.21                   |          | managed Kafka (private |
  |  SQL Server AG 10.20.30.11-12              |          | endpoint) / cloud APIs |
  |  (istio-sidecar + node agent)              |          +-----------^-----------+
  +---------------------^----------------------+                      |
                        | routed L3 (no NAT)                          | IPsec site-to-site VPN
                        |                                             | (IKEv2, AES-GCM-256, BGP over tunnel)
  +---------------------+---------------------------------------------+-----------+
  |  Core firewall / VPN concentrator (HA pair)                                    |
  +---------+------------------------------+-----------------------------+--------+
            | internal VLAN                 | DMZ VLAN                    | egress NAT (fixed public IPs)
   internal-pool VIP                  public-pool VIPs                     |
   (istio-internal-gateway:           (Kong, istio-ingressgateway)         |
    443, 15012, 15017, 15443)                                              |
  +---------+------------------------------+-----------------------------+--------+
  |  MicroK8s HA cluster: edge nodes (workload-tier=edge) host the gateways and   |
  |  istio-egressgateway; only edge nodes are allowed out by the firewall          |
  +-------------------------------------------------------------------------------+
```

* **Site-to-site VPN**: an IPsec (IKEv2) tunnel pair from the datacenter firewall HA pair to the cloud
  VPN gateway. Use BGP over the tunnels so failover is automatic, and turn on dead-peer detection.
  The cloud CIDRs, the datacenter CIDRs and the cluster's node CIDRs must not overlap. Pod and service CIDRs
  never leave the cluster: traffic leaves through the egress gateway pods, which use node IPs of the edge nodes.
* **Firewall rules** (default deny):
  * edge nodes → Internet :443 (SaaS) and → cloud Kafka private endpoints :9093 through the VPN
  * legacy VMs → `internal-pool` VIP :15012 and :15017 (istiod through the internal gateway), :15443 (mesh traffic)
  * cluster nodes → legacy VMs :1433 and :8080, plus :15008/:15443 when the VMs are modelled as a separate network
  * partner/branch networks over the VPN → `internal-pool` VIP :443 only (`*.internal.example.local`)
* **DNS**: conditional forwarding between the datacenter DNS and CoreDNS (`*.svc.cluster.local` is served
  inside the cluster only). `*.internal.example.local` and `*.ops.example.local` resolve to the internal VIP.
  Cloud private-endpoint names resolve through the cloud DNS forwarder over the VPN.
* **MTU**: IPsec adds overhead. Set MSS clamping of 1360 on the tunnel, or lower the Calico/VXLAN MTU if pods
  talk across the tunnel directly.

## (a) Legacy VMs in the mesh (VM mesh expansion)

1. Create the WorkloadGroup and ServiceAccount (this directory), then generate the VM bootstrap bundle:
   `istioctl x workload entry configure -f workloadgroup.yaml -o vm-files --clusterID cluster1 --autoregister`.
   Add `--ingressIP <internal-pool VIP of istio-internal-gateway>` so the VMs reach istiod at 15012/15017
   through `istio-internal/istiod-gateway`.
2. Install the `istio-sidecar` package on each VM (Windows Server SQL hosts: front them with a small Linux
   VM running the sidecar as a TCP proxy, or use the "non-mesh" variant below). Copy `vm-files`, then start
   `istio.service`.
3. Pods call `erp-sqlserver.legacy-vms.svc.cluster.local:1433` and `erp-api.legacy-vms.svc.cluster.local:8080`.
   Traffic uses mTLS with SPIFFE identities, and AuthorizationPolicies apply on both sides.
4. If the VMs cannot run a sidecar, replace the WorkloadEntries with a `MESH_EXTERNAL` ServiceEntry
   (`resolution: STATIC`, `endpoints: [{address: 10.20.30.11}]`, port `1433 TCP`). Route it through the
   egress gateway if the firewall only allows the edge nodes.

## (b) SaaS API with TLS origination on the egress gateway

* Applications call `http://api.payments-saas.example.com`. The sidecar upgrades the hop to mTLS towards
  `istio-egressgateway`, and the gateway originates TLS (with SNI) to the provider.
* Resilience lives in the VirtualService and DestinationRule: 10s timeout, 3 retries with a 3s per-try
  timeout, a connection pool, and outlier detection that ejects failing endpoints (circuit breaker).
  `maxRetries` caps concurrent retries so they cannot turn into a retry storm.
* The egress AuthorizationPolicy limits which namespaces may use this exit. Envoy access logs and traces
  record every call.
* Provider credentials (API keys, OAuth client secrets) stay in the application. They come from Vault via
  ExternalSecrets at `secret/tenants/<tenant>/<service>`.

## (c) Managed Kafka / cloud services

* Clients keep end-to-end TLS/SASL, and the egress gateway routes each connection by SNI (`PASSTHROUGH`).
  Every advertised broker host must be listed, because Kafka clients connect to each broker by name.
* Typical uses: MirrorMaker2 from `data-kafka` for DR or analytics, or SaaS event integrations.
* For other managed services (object storage, Service Bus, and so on), copy the pattern: HTTPS gets a
  ServiceEntry plus TLS origination, and TLS-native protocols get a ServiceEntry plus passthrough.

## Operations

* A new external dependency needs a ServiceEntry, which is added by a merge request to this directory or
  to `gitops/platform/data`. The `apps` AppProject blacklists ServiceEntry, so tenants cannot open egress
  themselves.
* Check the configuration with `istioctl proxy-config cluster <pod> | grep payments-saas` and
  `istioctl x describe pod <pod>`.
* To observe egress, use the Kiali graph (`kiali.ops.example.local`) and the egress gateway access logs
  (index `logs-istio-egress`).
