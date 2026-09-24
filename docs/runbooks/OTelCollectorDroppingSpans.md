# OTelCollectorDroppingSpans

Also used by `OTelCollectorQueueFull`, `OTelCollectorEnqueueFailed` and `OTelCollectorRefusingData`
(`gitops/platform/observability/alerts/manifests/observability-rules.yaml`). All carry `namespace: observability`.

## Severity

| Alert | Severity | Condition | `for` |
|---|---|---|---|
| `OTelCollectorDroppingSpans` | warning | > 1 % of spans fail to export, per `pod`/`exporter` | 10m |
| `OTelCollectorQueueFull` | critical | `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8` | 5m |
| `OTelCollectorEnqueueFailed` | critical | `rate(otelcol_exporter_enqueue_failed_(spans\|metric_points\|log_records)) > 0` — data dropped | 2m |
| `OTelCollectorRefusingData` | warning | `rate(otelcol_receiver_refused_*) > 0` — memory_limiter back-pressure | 5m |

## Meaning

```promql
sum by (namespace, pod, exporter) (rate(otelcol_exporter_send_failed_spans[5m]))
/ (sum by (...) (rate(otelcol_exporter_sent_spans[5m])) + sum by (...) (rate(otelcol_exporter_send_failed_spans[5m]))) > 0.01
```

Two collector tiers (OpenTelemetryCollector CRs in `gitops/platform/observability/opentelemetry/manifests`):

| CR | Workload | Exporters (`exporter` label) | Downstream |
|---|---|---|---|
| `otel` (gateway, Service `otel-collector:4317/4318`, HPA 3..12) | Deployment `otel-collector` | `load_balancing/sampler` (queue 10000), `otlp_grpc/apm` (logs, queue 5000), `prometheus` (:8889) | `otel-sampler-collector-headless:4317`, APM Server |
| `otel-sampler` (tail sampling, 3 replicas) | StatefulSet `otel-sampler-collector` | `otlp_grpc/apm` (queue 10000, retry 300 s) | `apm-server-apm-http.logging:8200` → Elasticsearch |

Failed sends are retried from the sending queue; when the queue is full, new data is dropped.

## Impact

Missing traces / APM errors in Kibana (sampled traces lost), gaps in `logs-apm.*`. Spanmetrics
(`traces_span_metrics_*`, computed on 100 % of spans in the gateway before export) keep working, so RED
dashboards stay correct.

## Diagnosis

```bash
kubectl -n observability get opentelemetrycollectors,pods,hpa -o wide
kubectl -n observability logs deploy/otel-collector --tail=200 | grep -iE 'error|drop|refus|queue'
kubectl -n observability logs otel-sampler-collector-0 --tail=200 | grep -iE 'error|drop|export'
kubectl -n logging get apmserver apm-server; kubectl -n logging get pods -l apm.k8s.elastic.co/name=apm-server
kubectl -n logging logs -l apm.k8s.elastic.co/name=apm-server --tail=100 | grep -iE 'error|429|queue'
```

```promql
sum by (pod, exporter) (rate(otelcol_exporter_send_failed_spans_total[5m]))
max by (pod, exporter) (otelcol_exporter_queue_size / otelcol_exporter_queue_capacity)
sum by (pod) (rate(otelcol_receiver_refused_spans_total[5m]))
container_memory_working_set_bytes{namespace="observability", container="otc-container"}
```

(metric names may lack the `_total` suffix depending on the collector version; the alerts match both.)

Which hop fails:
- `exporter="load_balancing/sampler"` on gateway pods → sampler pods down/restarting, DNS of the headless
  Service, sampler refusing (memory_limiter at 85 %).
- `exporter="otlp_grpc/apm"` on sampler pods → APM Server down / overloaded, TLS/secret token
  (`apm-server-credentials`), or Elasticsearch rejecting writes (red, flood stage, heap).

## Mitigation

1. Fix the downstream first: APM Server (3 replicas) and Elasticsearch
   ([ElasticsearchClusterRed](ElasticsearchClusterRed.md), [ElasticsearchHeapHigh](ElasticsearchHeapHigh.md)).
2. Sampler overloaded / OOM: raise `replicas` and memory of `otel-sampler` in `collector-sampler.yaml` (Git);
   the gateway's DNS resolver picks new replicas up within 15 s (trace routing reshuffles briefly).
3. Gateway refusing (memory_limiter 80 %): verify the HPA can scale (max 12); raise `maxReplicas` or memory.
4. APM token/TLS errors: check the ExternalSecret that copies the ECK APM token
   (`kubectl -n observability get externalsecret`, `apm-credentials.yaml`) and restart the collectors.
5. A single app flooding spans: identify it (`sum by (service_name) (rate(traces_span_metrics_calls_total[5m]))`)
   and reduce its sampling / fix the loop.

## Escalation

Warning → `#platform-alerts`; queue full / enqueue failed (data loss) → on-call. Observability owners.

## Related

- [ElasticsearchClusterRed](ElasticsearchClusterRed.md), [FluentBitOutputErrors](FluentBitOutputErrors.md)
- `gitops/platform/observability/README.md` (Traces / APM)
