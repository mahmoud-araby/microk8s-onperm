# RolloutAborted

Also used by `RolloutAnalysisFailed` (`gitops/platform/observability/alerts/manifests/platform-rules.yaml`).

## Severity

| Alert | Severity | Expression | `for` |
|---|---|---|---|
| `RolloutAborted` | warning | `max by (namespace, name) (rollout_info{phase="Degraded"}) == 1 or max by (namespace, name) (rollout_phase{phase=~"Aborted\|Error\|Timeout"}) == 1` | 1m |
| `RolloutAnalysisFailed` | warning | `max by (namespace, name) (analysis_run_info{phase=~"Failed\|Error"}) == 1` | 0m |

The per-release chart alert `<Service>RolloutDegraded` (critical) fires for the same condition — see
[high-error-rate](high-error-rate.md#rolloutdegraded).

## Meaning

An Argo Rollout (`charts/microservice` → `Rollout` named `<service>-<version>`, e.g. `orders-v1` in
`tenant-acme`) aborted its canary: the background `AnalysisRun` of AnalysisTemplate `<service>-<version>`
failed, the rollout hit `progressDeadlineSeconds: 600`, or someone aborted it. Traffic was shifted back to
the stable ReplicaSet (Istio VirtualService weights) and the canary is scaled down after 30 s.

Default canary (`charts/microservice/values.yaml`): steps 5 % → 2m → 25 % → 5m → 50 % → 5m → 100 %;
analysis every 1m over a 2m window, `failureLimit: 2`, on the canary Service `<fullname>-canary`:
`success-rate >= 0.99` (non-5xx) and `p95-latency <= 500` ms. Services may override these in
`gitops/apps/<service>/values*.yaml`.

## Impact

Users are back on the stable version (low impact), but the release is blocked: the Argo CD application
(`<tenant>-<service>-<version>`) turns Degraded and the ApplicationSet RollingSync stops before the next
ring.

## Diagnosis

```bash
kubectl argo rollouts get rollout orders-v1 -n tenant-acme        # steps, revisions, abort message
kubectl -n tenant-acme get analysisruns --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n tenant-acme describe analysisrun <run>                  # measured values per metric
kubectl -n tenant-acme logs -l app.kubernetes.io/instance=orders-v1,role=canary -c orders --tail=200
```

Rollouts dashboard: `https://rollouts.ops.example.local`. Grafana **Microservice RED** → *Canary vs stable
(by revision = image tag)*: *Error ratio by revision*, *p95 latency by revision*, *Argo Rollouts phase*.

Canary queries (as used by the AnalysisTemplate):

```promql
sum(rate(istio_requests_total{reporter="destination",destination_service_name="orders-v1-canary",
  destination_service_namespace="tenant-acme",response_code!~"5.."}[2m]))
/ sum(rate(istio_requests_total{reporter="destination",destination_service_name="orders-v1-canary",
  destination_service_namespace="tenant-acme"}[2m]))
```

Kibana APM → service `orders-v1`, filter `service.version : "<new tag>"` → errors / slow transactions.
Analysis `Error` (not `Failed`) usually means Prometheus was unreachable
(`kube-prometheus-stack-prometheus.monitoring:9090`) — check before blaming the release.

## Mitigation

1. Nothing urgent for users: stable is serving. Confirm with `kubectl argo rollouts get rollout ...` that the
   stable ReplicaSet is fully available.
2. Real regression: revert the image tag commit in `gitops/apps/<service>/values-<version>.yaml` (CI bump), or
   pin the previous `imageTag` in `gitops/tenants/<tenant>/services/<service>-<version>.yaml`. The Rollout
   returns to Healthy on the old revision.
3. False positive (analysis `Error`, a noisy threshold, too little traffic): fix the cause, then
   `kubectl argo rollouts retry rollout orders-v1 -n tenant-acme`. Only the service owner may
   `kubectl argo rollouts promote --full` to skip analysis.
4. Timeout: canary pods never became Ready — debug like a crash loop
   ([high-error-rate](high-error-rate.md#podrestarts)).

## Escalation

`#platform-alerts` and the tenant channel; owner is the service team that shipped the image. Platform on-call
only if many rollouts abort at once (Prometheus / Istio issue).

## Related

- [ArgoCDAppDegraded](ArgoCDAppDegraded.md), [SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md)
- `charts/microservice/templates/analysistemplate.yaml`, `gitops/apps/README.md` (release flow)
