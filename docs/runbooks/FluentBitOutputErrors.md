# FluentBitOutputErrors

Also used by `FluentBitRetriesExhausted` and `FluentBitDroppedRecords`
(`gitops/platform/observability/alerts/manifests/observability-rules.yaml`).

## Severity

| Alert | Severity | Expression | `for` |
|---|---|---|---|
| `FluentBitOutputErrors` | warning | `sum by (pod, name) (rate(fluentbit_output_errors_total[5m])) > 0` | 10m |
| `FluentBitRetriesExhausted` | critical | `sum by (pod, name) (increase(fluentbit_output_retries_failed_total[10m])) > 0` | 0m |
| `FluentBitDroppedRecords` | critical | `sum by (pod, name) (increase(fluentbit_output_dropped_records_total[10m])) > 0` | 0m |

All carry `namespace: logging`.

## Meaning

A Fluent Bit pod (DaemonSet `fluent-bit`, namespace `logging`, one per node) fails to ship chunks through an
output. `name` is the output alias: **`es-k8s`** (container logs → data streams `logs-<namespace>-k8s`, buffer
limit 8G) or **`es-node`** (host services `kubelite`/`containerd`/`k8s-dqlite` → `logs-node-k8s`, 1G). Both
write to `elasticsearch-es-http.logging.svc.cluster.local:9200` as user `fluent-bit` (role `fluent_bit_writer`:
`create_doc`, `auto_configure` on `logs-*-k8s`), `Write_Operation create`, `Generate_ID On`, `Retry_Limit 10`.

- Output errors: chunks are retried; logs are safe in the filesystem buffer (host `/var/lib/fluent-bit`).
- Retries exhausted / dropped records: **log data was lost** on that node.

## Impact

Logs of the node are delayed in Kibana (or lost for critical alerts); log-based investigations and Grafana's
*Elasticsearch Logs* datasource show gaps. A full buffer also consumes node disk.

## Diagnosis

```bash
kubectl -n logging get pods -l app.kubernetes.io/name=fluent-bit -o wide
kubectl -n logging logs <pod> --tail=200 | grep -iE 'error|warn|retry|http_status'
kubectl -n logging port-forward <pod> 2020
curl -s localhost:2020/api/v1/metrics | jq '.output'
curl -s localhost:2020/api/v1/storage | jq          # chunks up/down, buffer usage
```

Elasticsearch side:

```bash
PW=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging port-forward svc/elasticsearch-es-http 9200 &
curl -sk -u elastic:$PW https://localhost:9200/_cluster/health?pretty
curl -sk -u elastic:$PW "https://localhost:9200/_cat/thread_pool/write?v&h=node_name,active,queue,rejected"
```

```promql
sum by (name) (rate(fluentbit_output_errors_total[5m]))
sum by (pod) (rate(fluentbit_output_retries_total[5m]))
```

Grafana: upstream **Fluent Bit** dashboard (folder Platform). Typical causes by error:
- connection refused / timeout → Elasticsearch down or red ([ElasticsearchClusterRed](ElasticsearchClusterRed.md));
- HTTP 429 / `es_rejected_execution_exception` → write queue full ([ElasticsearchHeapHigh](ElasticsearchHeapHigh.md));
- `cluster_block_exception` / read-only → flood-stage watermark ([ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md));
- HTTP 401/403 → `es-user-fluent-bit` Secret / role mismatch (password rotated in Vault `secret/platform/elastic`);
- mapping errors (`mapper_parsing_exception`, dropped records) → an app logs a field with conflicting types.
  `Trace_Error` is `Off`; enable it temporarily in `gitops/platform/observability/fluent-bit/values.yaml` to
  see the rejected document.

## Mitigation

1. Fix Elasticsearch first (health, disk, heap); Fluent Bit drains its buffer automatically afterwards.
2. Credentials: verify `kubectl -n logging get secret es-user-fluent-bit` matches Vault; restart the DaemonSet
   after a rotation: `kubectl -n logging rollout restart ds/fluent-bit`.
3. Mapping conflicts: fix the application's log field type (contract: JSON on stdout with stable field types);
   for an urgent case, add an explicit mapping in the index template (es-bootstrap Job) and roll over the data
   stream (`POST /logs-<namespace>-k8s/_rollover`).
4. Do not delete the host buffer directory while Elasticsearch is down — that is the only copy of the logs.
5. After `RetriesExhausted` / `DroppedRecords`: record the time window and node as a log gap for the affected
   teams.

## Escalation

Warning → `#platform-alerts`, observability owners. Data loss alerts (critical) → on-call; inform security /
audit if the node's logs are compliance-relevant.

## Related

- [ElasticsearchClusterRed](ElasticsearchClusterRed.md), [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md),
  [NodeDiskPressureCritical](NodeDiskPressureCritical.md)
- `gitops/platform/observability/README.md` (Logs)
