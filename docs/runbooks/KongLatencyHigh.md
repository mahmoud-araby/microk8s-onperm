# KongLatencyHigh

## Severity

warning (`for: 10m`), label `namespace: kong` — `gitops/platform/observability/alerts/manifests/edge-rules.yaml`.

## Meaning

p99 of the total request latency measured by Kong (Kong processing + upstream) for one Kong `service` is above
2 s, with more than 1 rps of traffic:

```promql
histogram_quantile(0.99, sum by (service, le) (rate(kong_request_latency_ms_bucket[5m]))) > 2000
and sum by (service) (rate(kong_request_latency_ms_count[5m])) > 1
```

Latency metrics are enabled by `KongClusterPlugin` `global-prometheus` (`latency_metrics: true`).
Timeout budget (docs/resilience.md): client → Kong 60 s, Kong → service route timeout 10 s with 3 mesh retries.

## Impact

Slow public API for the route's clients; long tails often precede 5xx (timeouts) and client retries that add
load.

## Diagnosis

1. Grafana **Kong API Gateway** → *p99 total latency*, per-service panels.
2. Split Kong vs upstream time:
   ```promql
   histogram_quantile(0.99, sum by (service, le) (rate(kong_upstream_latency_ms_bucket[5m])))  # upstream
   histogram_quantile(0.99, sum by (service, le) (rate(kong_kong_latency_ms_bucket[5m])))      # Kong plugins
   ```
   - Upstream dominates → the service or its dependencies are slow: Grafana **Microservice RED** (p95/p99,
     *Top operations p95*, exemplars → Kibana APM trace), [SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md).
   - Kong time dominates → plugins: the Redis-backed `rate-limiting` (`policy: redis` →
     `redis.data-redis.svc.cluster.local:6379`, timeout 2000 ms), JWT/OIDC, `opentelemetry`; or Kong pods
     saturated.
3. Kong pod saturation:
   ```bash
   kubectl -n kong top pods
   kubectl -n kong get hpa
   kubectl -n kong logs deploy/kong-gateway -c proxy --tail=200 | grep -iE 'timeout|redis|upstream'
   ```
4. Retries hiding latency: *Circuit Breakers & Retries* dashboard → *Retries / s by upstream* (mesh retries on
   `5xx,reset,connect-failure` multiply latency).
5. Kibana APM: service `kong-gateway` (Kong's OpenTelemetry plugin, 10 % sampling) → slow transactions for the
   route; follow the trace into the upstream service.

## Mitigation

1. Upstream slow → scale the service (HPA max in the tenant descriptor), roll back a recent release, or fix the
   dependency (data runbooks).
2. Redis latency in the rate limiter → check Redis (`RedisMemoryHigh`, `RedisRejectedConnections`,
   [Redis failover](../../gitops/platform/data/README.md#runbook-redis-failover)); as a temporary measure the
   plugin policy can be switched to `local` for the affected route in Git (weaker global limits).
3. Kong saturated → raise `gateway.autoscaling.maxReplicas` / resources in `gitops/platform/core/kong/values.yaml`;
   edge nodes (`workload-tier=edge`) must have capacity.
4. Abusive client → tighten the route's `kong.rateLimit` or block via ip-restriction.

## Escalation

`#platform-alerts`. Owning service team if upstream latency; platform on-call (edge) if Kong itself.

## Related

- [Kong5xxSurge](Kong5xxSurge.md), [SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md), [SyntheticProbeFailed](SyntheticProbeFailed.md)
- `gitops/platform/core/kong/values.yaml`, `docs/resilience.md`
