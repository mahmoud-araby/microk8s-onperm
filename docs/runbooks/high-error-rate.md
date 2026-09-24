# Per-service alerts (`charts/microservice`)

Every release of `charts/microservice` renders a `PrometheusRule` named `<fullname>` in its namespace
(`charts/microservice/templates/prometheusrule.yaml`). `<fullname>` = `<service>-<version>` (e.g. `orders-v1`),
and the alert prefix is its CamelCase form: release `orders-v1` → `OrdersV1HighErrorRate`,
`OrdersV1HighLatencyP95`, ... Labels: `namespace`, `service: <fullname>`, and `tenant` on the error/latency
alerts (routes to `#tenant-<t>-alerts` as well). Thresholds are chart values under `prometheusRule`
(defaults: `errorRateThreshold: 0.05`, `p95LatencyMs: 1000`, `restartThreshold: 3`); a service can override them
in `gitops/apps/<service>/values*.yaml` or the tenant descriptor `values`.
Only `<Service>HighErrorRate` carries `runbook_url`; this file covers all six alerts.

Examples below use `orders-v1` in `tenant-acme` (Argo CD app `acme-orders-v1`); the app container is named
after the service (`orders`).

## HighErrorRate

**Severity:** critical, `for: 5m` (requires `istio.enabled`).

```promql
sum(rate(istio_requests_total{reporter="destination",destination_service_namespace="tenant-acme",
  destination_service_name=~"orders-v1|orders-v1-canary",response_code=~"5.."}[5m]))
/ sum(rate(istio_requests_total{...same selector...}[5m])) > 0.05
```

More than 5 % of requests served by the release (stable + canary) return 5xx. **Impact:** clients of this
service/tenant see errors; the SLO budget burns 50x ([SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md)).

**Diagnosis**
1. Grafana **Microservice RED** (`/d/microservice-red`, variables namespace/service): *Responses by code*,
   *Error ratio by revision* (canary vs stable), *Envoy response flags*, *Callers (client side)*.
2. App vs mesh: response flags `UH`/`UF`/`UO`/`URX` point to the mesh/pods, plain 500s to the app.
3. Logs: `kubectl -n tenant-acme logs -l app.kubernetes.io/instance=orders-v1 -c orders --tail=200 --prefix`;
   Kibana `logs-*-k8s`: `kubernetes.namespace_name : "tenant-acme" and level : "error"` (pivot on `trace_id`).
4. Traces: Kibana → APM → service `orders-v1` → *Errors* (all error/5xx traces are kept).
5. Dependencies: readiness checks DB/Redis/broker → **Data Services Summary**, data alerts.
6. Recent changes: `kubectl argo rollouts get rollout orders-v1 -n tenant-acme`, `argocd app history acme-orders-v1`.

**Mitigation:** abort a running canary (`kubectl argo rollouts abort orders-v1 -n tenant-acme`); revert the image
tag in `gitops/apps/orders/values-v1.yaml` or pin `imageTag` in `gitops/tenants/acme/services/orders-v1.yaml`;
fix/fail over the dependency (data runbooks); scale out if saturated (see AutoscalerAtMax).
**Escalation:** on-call + owning service team; platform on-call if several services fail together.

## HighLatencyP95

**Severity:** warning, `for: 10m`.
`histogram_quantile(0.95, sum by (le) (rate(istio_request_duration_milliseconds_bucket{<same selector>}[5m]))) > 1000`.

Server-side p95 above 1 s. Diagnose with Microservice RED *Latency percentiles*, *Top operations p95*
(exemplars → APM trace), APM *Dependencies*, CPU throttling (`container_cpu_cfs_throttled_periods_total`) and
HPA state. Mitigate by scaling, rolling back, or fixing the slow dependency; see
[SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md).

## PodRestarts

**Severity:** warning, `for: 5m`.
`sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace="tenant-acme",pod=~"orders-v1-[a-z0-9]+-[a-z0-9]+"}[15m])) > 3`.

```bash
kubectl -n tenant-acme get pods -l app.kubernetes.io/instance=orders-v1
kubectl -n tenant-acme describe pod <pod> | grep -A5 'Last State'   # OOMKilled? exit code?
kubectl -n tenant-acme logs <pod> -c orders --previous --tail=100
```

`OOMKilled` → raise memory limit in Git; liveness failures (`/health/live`) → app hang / GC; startup failures
(`/health/startup`, up to 150 s) or `wait-for-*` init containers stuck → dependency unreachable (NetworkPolicy,
ExternalSecret `orders-v1-secrets` not synced: `kubectl -n tenant-acme describe externalsecret orders-v1-secrets`).
Grafana Microservice RED → *Container restarts (1h)*.

## CircuitBreakerOpen

**Severity:** warning, `for: 2m`.
`sum(envoy_cluster_outlier_detection_ejections_active{cluster_name=~"outbound\\|80\\|\\|(orders-v1|orders-v1-canary)\\.tenant-acme\\.svc\\.cluster\\.local"}) > 0`.

Callers' sidecars (Kong, other services) eject endpoints of this release after 5 consecutive 5xx / gateway
errors (DestinationRule `outlierDetection`, 30 s base ejection, max 50 %). Needs the `.*outlier_detection.*`
stats inclusion (chart default). Diagnose on **Circuit Breakers & Retries** (`/d/circuit-breakers`):
*Active ejections by upstream*, *Healthy vs total upstream hosts*; find the failing pod
(`kubectl -n tenant-acme get pods -l app.kubernetes.io/instance=orders-v1 -o wide`, logs, node). Mitigate by
fixing/deleting the bad pod (a single sick pod on a bad node) or treating it as HighErrorRate. See
`docs/resilience.md`.

## AutoscalerAtMax

**Severity:** warning, `for: 15m` (only when HPA or KEDA is enabled).
`max(kube_horizontalpodautoscaler_status_current_replicas{namespace="tenant-acme",horizontalpodautoscaler=~"(keda-hpa-)?orders-v1"}) >= <maxReplicas>`
(chart default HPA 50, KEDA 100; `acme` pins `maxReplicas: 10` for orders-v1).

```bash
kubectl -n tenant-acme get hpa; kubectl -n tenant-acme describe hpa orders-v1   # or keda-hpa-orders-v1
kubectl -n tenant-acme get scaledobject orders-v1 2>/dev/null
kubectl top nodes -l workload-tier=apps
```

Check whether the load is legitimate (Kong *Requests / s by service*) or a retry storm / slow dependency
inflating CPU. Mitigate: raise `autoscaling.hpa.maxReplicas` (or `keda.maxReplicas`) in the tenant descriptor
`values` via Git, confirm ResourceQuota of the tenant namespace (`kubectl -n tenant-acme describe quota`) and
`apps` pool capacity allow it; rate-limit abusive consumers at Kong.

## RolloutDegraded

**Severity:** critical, `for: 1m` (only when `rollout.enabled`).
`max(rollout_info{namespace="tenant-acme",name="orders-v1",phase=~"Degraded|Error"}) == 1`.

The canary of this release was aborted (analysis failed / progress deadline). Stable still serves traffic.
Follow [RolloutAborted](RolloutAborted.md).

## Related

- [SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md), [SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md),
  [Kong5xxSurge](Kong5xxSurge.md), [RolloutAborted](RolloutAborted.md), [ArgoCDAppDegraded](ArgoCDAppDegraded.md)
- `charts/microservice/README.md`, `gitops/platform/data/README.md#runbooks`
