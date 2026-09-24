# SLOLatencyBudgetBurn (Fast / Slow)

Covers `SLOLatencyBudgetBurnFast` and `SLOLatencyBudgetBurnSlow`
(`gitops/platform/observability/alerts/manifests/slo-rules.yaml`, group `slo-burn-rate.alerts`).

## Severity

| Alert | Severity | Labels | `for` |
|---|---|---|---|
| `SLOLatencyBudgetBurnFast` | critical (page) | `slo=latency`, `slo_alert=fast-burn` | 2m |
| `SLOLatencyBudgetBurnSlow` | warning (ticket) | `slo=latency`, `slo_alert=slow-burn` | 15m |

## Meaning

Latency SLO: 99 % of mesh requests complete in < 500 ms over 30 days (budget 1 % slow requests). The SLI
is the share of requests *above* the `le="500"` bucket of `istio_request_duration_milliseconds`
(`reporter="destination"`), per `namespace` + `service`:

```promql
slo:sli_latency_slow:ratio_rate5m = 1 - (slo:sli_latency_fast:rate5m / slo:sli_latency_total:rate5m)
# fast: 14.4x over 1h AND 5m, or 6x over 6h AND 30m
slo:sli_latency_slow:ratio_rate1h > (14.4 * 0.01) and slo:sli_latency_slow:ratio_rate5m > (14.4 * 0.01)
# slow: 3x over 1d AND 2h, or 1x over 3d AND 6h;  both require slo:sli_requests:rate1h > 0.1
```

Fast burn means > 14.4 % of requests (1h) are slower than 500 ms. Latency is measured server-side at the
callee's sidecar, so it includes the app and its dependencies, not Kong.

## Impact

Slow responses for the tenant's clients; upstream timeouts (Istio route timeout 10 s, 3 retries) can turn
latency into 5xx and burn the availability SLO as well.

## Diagnosis

1. Grafana **Microservice RED** (`https://grafana.ops.example.local/d/microservice-red`) for the alert's
   `namespace` / `service`: p95 / p99 panels, *Top operations p95* (click an exemplar ◆ to open the trace in
   Kibana APM), *Canary vs stable* row.
2. PromQL:
   ```promql
   slo:sli_latency_slow:ratio_rate5m{namespace="tenant-acme", service="orders-v1"}
   histogram_quantile(0.95, sum by (le) (rate(istio_request_duration_milliseconds_bucket{reporter="destination",
     destination_service_namespace="tenant-acme", destination_service_name="orders-v1"}[5m])))
   # CPU throttling / saturation
   sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="tenant-acme", pod=~"orders-v1-.*"}[5m]))
   ```
3. Kibana → APM → service `orders-v1` → *Transactions* (latency distribution) and *Dependencies* (slow
   Postgres / Redis / RabbitMQ / Kafka / HTTP calls). All traces >= 1 s are kept by `otel-sampler`.
4. Dependency health: **Data Services Summary** dashboard; PgBouncer waits (`PgBouncerClientsWaiting`),
   Postgres replication/locks, Redis latency.
5. Scaling state:
   ```bash
   kubectl -n tenant-acme get hpa,pods -l app.kubernetes.io/instance=orders-v1
   kubectl -n tenant-acme top pods -l app.kubernetes.io/instance=orders-v1 --containers
   ```
6. Node pressure / noisy neighbours on the `apps` pool: `kubectl top nodes -l workload-tier=apps`.

## Mitigation

1. Recent release? Abort the canary: `kubectl argo rollouts abort orders-v1 -n tenant-acme`, then revert the
   image tag in Git (`gitops/apps/<service>/values-<version>.yaml`) or pin `imageTag` in the tenant descriptor.
2. Saturated pods: scale out — HPA at max → raise `autoscaling.hpa.maxReplicas` (or KEDA `maxReplicas`) in
   the tenant descriptor `values`; CPU-throttled → raise `resources.limits.cpu` in Git.
3. Slow dependency: follow the data runbooks (`gitops/platform/data/README.md#runbooks`), e.g. PgBouncer pool
   exhaustion, Postgres failover.
4. Shed load if needed: temporarily lower Kong `rateLimit.minute` for the noisy consumer / tenant.
5. Slow burn only: ticket for the owning team (query tuning, caching, indexes).

## Escalation

Fast burn → on-call (PagerDuty) + tenant channel; owning service team first. Platform on-call if many
services degrade together (Istio, node pool, data tier).

## Related

- [high-error-rate#highlatencyp95](high-error-rate.md#highlatencyp95) (per-service p95 > 1000 ms alert)
- [SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md), [KongLatencyHigh](KongLatencyHigh.md), [NodeUnderPressure](NodeUnderPressure.md)
