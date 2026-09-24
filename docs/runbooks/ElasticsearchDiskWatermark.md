# ElasticsearchDiskWatermark

## Severity

warning (`for: 15m`) — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.

## Meaning

```promql
(1 - elasticsearch_filesystem_data_available_bytes / elasticsearch_filesystem_data_size_bytes) > 0.80
```

The data path of Elasticsearch node `{{ $labels.name }}` (e.g. `elasticsearch-es-hot-1`) is more than 80 %
full. Cluster settings applied by the `es-bootstrap` Job: watermark **low 85 %** (no new shards allocated to
the node), **high 90 %** (shards relocated away), **flood_stage 95 %** (indices with a shard on the node become
read-only → ingest fails).

Volumes: `hot` 3 x 6Ti, `warm` 2 x 12Ti, `master` 3 x 20Gi, all `longhorn-db`. The capacity plan
(`gitops/platform/observability/README.md`, Retention & sizing) says: add a 4th hot node when hot disk passes 75 %.

## Impact

None yet at 80 %; this is the early warning. Past 85 %/90 % replicas stay unassigned (yellow) and shards
move around; at 95 % log ingestion (Fluent Bit) and APM writes fail for the affected indices.

## Diagnosis

```bash
PW=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging port-forward svc/elasticsearch-es-http 9200 &
ES="curl -sk -u elastic:$PW https://localhost:9200"
$ES/_cat/allocation?v\&s=disk.percent:desc
$ES/_cat/indices?v\&s=store.size:desc\&h=index,pri,rep,docs.count,store.size | head -20
$ES/_data_stream?pretty | grep -E '"name"|ilm_policy' | head -40
$ES/_ilm/explain/.ds-logs-*?only_errors=true\&pretty       # ILM stuck = retention not applied
```

```promql
topk(10, elasticsearch_data_stream_store_size_bytes)   # exporter runs with --es.data_stream
predict_linear(elasticsearch_filesystem_data_available_bytes[12h], 3*24*3600)
```

Kibana → Stack Management → Index Management / Data Streams: which namespace's `logs-<namespace>-k8s` grows
fastest (a noisy tenant or debug logging).

## Mitigation

1. ILM errors (a stuck rollover/forcemerge/delete): fix and `$ES -XPOST '/<index>/_ilm/retry'`. Policies:
   `logs-k8s` (warm 7d, delete 30d), `apm-traces` (warm 2d, delete 7d), `apm-logs` (delete 30d),
   `apm-metrics` (delete 90d).
2. Reduce volume at the source: a namespace logging at DEBUG, or Istio access logs — enabling the
   commented access-log filter `response.code >= 400 || response.duration > 1000` in
   `gitops/platform/core/istio/manifests/telemetry.yaml` cuts ~60 % of log volume.
3. Short-term relief: delete the oldest backing indices of the largest data stream **by exact name** (snapshots
   exist, SLM keeps 35 d) or shorten `delete.min_age` in the ILM policy in
   `gitops/platform/observability/elastic/manifests/es-bootstrap-job.yaml`.
4. Grow the volumes: raise the nodeSet `volumeClaimTemplates` storage in
   `gitops/platform/observability/elastic/manifests/elasticsearch.yaml` (Longhorn expands online; the
   Longhorn disk of that node must have room — [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md)).
5. Add a data node: raise `count` of the `hot` nodeSet (needs an `observability` node with enough NVMe).
6. Flood stage already hit: after freeing space, ES 8 releases the read-only block automatically; verify
   `$ES/_all/_settings/index.blocks*?pretty`.

## Escalation

`#platform-alerts`, observability owners. Hardware (new disks / nodes): platform lead.

## Related

- [ElasticsearchClusterYellow](ElasticsearchClusterYellow.md), [ElasticsearchClusterRed](ElasticsearchClusterRed.md),
  [FluentBitOutputErrors](FluentBitOutputErrors.md), [PlatformPVCFillingUp](PlatformPVCFillingUp.md)
