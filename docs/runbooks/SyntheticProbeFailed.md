# SyntheticProbeFailed

Also used by `SyntheticProbeFailedInternal` and `SyntheticProbeSlow`
(`gitops/platform/observability/alerts/manifests/edge-rules.yaml`).

## Severity

| Alert | Severity | Expression | `for` |
|---|---|---|---|
| `SyntheticProbeFailed` | critical | `probe_success{probe_group="public"} == 0` | 2m |
| `SyntheticProbeFailedInternal` | warning | `probe_success{probe_group=~"ops\|incluster"} == 0` | 5m |
| `SyntheticProbeSlow` | warning | `avg_over_time(probe_duration_seconds{probe_group="public"}[10m]) > 2` | 10m |

## Meaning

The blackbox exporter (`blackbox-exporter.monitoring.svc.cluster.local:9115`, 2 replicas) runs the `Probe` CRs
in `gitops/platform/observability/blackbox-exporter/manifests/probes.yaml` (namespace `monitoring`):

| Probe | Module | Targets | Group |
|---|---|---|---|
| `public-api` | `http_health_json` (2xx + body starts with `{`/`[`, TLS required) | `https://api.example.com/health` | public |
| `public-web` | `http_2xx` | `https://app.example.com/` | public |
| `ops-uis` | `http_ops_ui` (200/30x/401/403 OK, internal CA) | `argocd`, `grafana`, `kibana`, `kiali`, `rollouts`, `vault`, `harbor`, `keycloak`, `rabbitmq` `.ops.example.local` | ops |
| `observability-incluster`, `elastic-incluster`, `telemetry-ingest-tcp` | in-cluster health | Grafana, Alertmanager, Prometheus, Thanos Query Frontend, Kibana, ES, APM, OTLP ports | incluster |

Public probes go from inside the cluster through the public VIP (Kong `kong-gateway-proxy`, MetalLB
`public-pool`), so they test DNS, VIP, TLS certificate, Kong routing and the upstream.

## Impact

`SyntheticProbeFailed`: the public API or the web frontend is likely down for everyone. Internal: an ops UI or
observability component is unreachable (operators blind, not customer-facing).

## Diagnosis

1. Grafana **Platform Overview & SLOs** → *Public probes up*, *Probe success*, *Probe duration*.
2. Why did it fail — run the probe with debug output:
   ```bash
   kubectl -n monitoring port-forward svc/blackbox-exporter 9115
   curl -s 'http://localhost:9115/probe?module=http_health_json&target=https://api.example.com/health&debug=true'
   ```
   ```promql
   probe_http_status_code{instance="https://api.example.com/health"}
   probe_ssl_earliest_cert_expiry - time()
   probe_dns_lookup_time_seconds, probe_http_duration_seconds   # by phase: resolve/connect/tls/processing/transfer
   ```
3. From outside the cluster (to separate the VIP/network from the app):
   `curl -sv https://api.example.com/health` and compare with the VIP IP:
   `kubectl -n kong get svc kong-gateway-proxy -o wide`; MetalLB speakers: `kubectl -n metallb-system get pods`.
4. Kong healthy? `kubectl -n kong get pods`, [Kong5xxSurge](Kong5xxSurge.md). Upstream of `/health`: check
   the Kong route for `api.example.com/health` and its backing Service.
5. Internal probes: the Istio internal gateway (`kubectl -n istio-internal get pods,svc`), the `ops-wildcard`
   certificate ([CertificateExpiringSoon](CertificateExpiringSoon.md)), and the target component itself.
6. A single failing blackbox replica only → prober problem; check `kubectl -n monitoring logs deploy/blackbox-exporter`.

## Mitigation

1. Kong / upstream failure → follow [Kong5xxSurge](Kong5xxSurge.md) / [SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md).
2. VIP unreachable → check MetalLB (`metallb-system`), edge nodes (`workload-tier=edge`) Ready, and that
   `kong-gateway` pods run on edge nodes (`externalTrafficPolicy: Local` needs a local endpoint on the announcing node).
3. TLS error (expired / wrong chain) → [CertificateExpiringSoon](CertificateExpiringSoon.md).
4. Body check failing (HTML error page instead of JSON) → an intermediate proxy / Kong error page; inspect the
   debug output body.
5. Slow probe → [KongLatencyHigh](KongLatencyHigh.md).

## Escalation

Public probe → on-call immediately (customer-facing). Network team for VIP / firewall / DNS problems. Internal
probes → `#platform-alerts`.

## Related

- [Kong5xxSurge](Kong5xxSurge.md), [KongLatencyHigh](KongLatencyHigh.md), [CertificateExpiringSoon](CertificateExpiringSoon.md)
- `gitops/platform/observability/blackbox-exporter/`
