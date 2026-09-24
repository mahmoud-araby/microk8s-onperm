# SLOAvailabilityBudgetBurn (Fast / Slow)

Covers `SLOAvailabilityBudgetBurnFast` and `SLOAvailabilityBudgetBurnSlow`
(`gitops/platform/observability/alerts/manifests/slo-rules.yaml`, group `slo-burn-rate.alerts`).

## Severity

| Alert | Severity | Labels | `for` |
|---|---|---|---|
| `SLOAvailabilityBudgetBurnFast` | critical (page) | `slo=availability`, `slo_alert=fast-burn` | 2m |
| `SLOAvailabilityBudgetBurnSlow` | warning (ticket) | `slo=availability`, `slo_alert=slow-burn` | 15m |

Fast burn inhibits slow burn for the same `namespace`/`service`/`slo` (Alertmanager inhibit rule).

## Meaning

Availability SLO: 99.9 % of mesh requests are not 5xx over 30 days (error budget 0.1 %). The SLI comes from
Istio server-side telemetry (`istio_requests_total{reporter="destination"}`) aggregated per
`namespace` + `service` (= `destination_service_name`) by the `slo:sli_*` recording rules. `tenant` is
derived from `tenant-<x>` namespaces.

```promql
# fast: 14.4x over 1h AND 5m, or 6x over 6h AND 30m
slo:sli_error:ratio_rate1h > (14.4 * 0.001) and slo:sli_error:ratio_rate5m > (14.4 * 0.001)
# slow: 3x over 1d AND 2h, or 1x over 3d AND 6h
slo:sli_error:ratio_rate1d > (3 * 0.001) and slo:sli_error:ratio_rate2h > (3 * 0.001)
# both: ... and on (namespace, service) slo:sli_requests:rate1h > 0.1
```

Fast burn = ~2 % (1h) / ~5 % (6h) of the 30-day budget already spent; budget gone in about 2 days.
Slow burn = the budget will be exhausted before the end of the window.

## Impact

Clients of `{{namespace}}/{{service}}` (a tenant's service release, e.g. `tenant-acme/orders-v1`, or a
pooled release in `shared-services`) are receiving 5xx. Fast burn is a user-visible outage/partial outage.

## Diagnosis

1. Open Grafana **Platform Overview & SLOs** (`https://grafana.ops.example.local/d/platform-overview`) →
   *Service scorecard* and *Error ratio by tenant*; then **Microservice RED** (`/d/microservice-red`) with
   the alert's `namespace` / `service`.
2. Current error ratio and remaining budget:
   ```promql
   slo:sli_error:ratio_rate5m{namespace="tenant-acme", service="orders-v1"}
   slo:availability_error_budget_remaining:ratio30d{namespace="tenant-acme", service="orders-v1"}
   sum by (response_code, source_workload) (rate(istio_requests_total{reporter="destination",
     destination_service_namespace="tenant-acme", destination_service_name="orders-v1", response_code=~"5.."}[5m]))
   ```
   Split by revision (canary vs stable) with the *Canary vs stable* row of Microservice RED.
3. Recent change? `kubectl argo rollouts get rollout orders-v1 -n tenant-acme` and
   `argocd app history acme-orders-v1`; compare with `git log gitops/apps/orders/`.
4. Pods / dependencies:
   ```bash
   kubectl -n tenant-acme get pods -l app.kubernetes.io/instance=orders-v1 -o wide
   kubectl -n tenant-acme logs -l app.kubernetes.io/instance=orders-v1 -c orders --tail=100 --prefix
   # app container = service name (charts/microservice); sidecar = istio-proxy
   ```
   Readiness checks DB/Redis/broker: check the **Data Services Summary** dashboard and data alerts.
5. Envoy response flags (UH = no healthy upstream, UO = overflow, URX = retries exhausted, UT = timeout):
   Microservice RED panel *Envoy response flags*, or Kibana Discover, data view `logs-*-k8s`:
   `kubernetes.namespace_name : "tenant-acme" and response_code >= 500 and authority : orders-v1*`.
6. Traces: Kibana → APM → service `orders-v1` → *Errors* / failed transactions (all 5xx traces are kept by
   `otel-sampler`).

## Mitigation

1. If a canary is in progress or just finished: `kubectl argo rollouts abort orders-v1 -n tenant-acme`
   (traffic returns to stable), then revert the image tag commit in `gitops/apps/<service>/values-<version>.yaml`
   or pin `imageTag` in `gitops/tenants/<tenant>/services/<service>-<version>.yaml`.
2. Capacity: if pods are saturated / at max replicas, raise `autoscaling.hpa.maxReplicas` in the tenant
   descriptor `values` (Git) — see [high-error-rate#autoscaleratmax](high-error-rate.md#autoscaleratmax).
3. Dependency failure: follow the data runbook (`gitops/platform/data/README.md#runbooks`).
4. Circuit breaker ejecting all endpoints: see [high-error-rate#circuitbreakeropen](high-error-rate.md#circuitbreakeropen).
5. Slow burn only: open a ticket for the owning team; no emergency action required, but freeze risky
   releases of that service until the burn stops.

## Escalation

Fast burn pages on-call (`oncall-critical` → PagerDuty + Slack) and the tenant channel (`#tenant-<t>-alerts`).
Escalate to the owning service team immediately; to platform on-call if several services/tenants burn at the
same time (shared cause: Kong, Istio, data tier).

## Related

- [high-error-rate](high-error-rate.md) (per-service `<Service>HighErrorRate`, fires at 5 % over 5m)
- [SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md), [Kong5xxSurge](Kong5xxSurge.md), [RolloutAborted](RolloutAborted.md)
- `gitops/platform/observability/README.md` → Alerting / SLOs
