# ElasticsearchClusterRed

## Severity

critical (`for: 2m`) — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.
Pages on-call. Inhibits `ElasticsearchClusterYellow` (same `cluster`).

## Meaning

```promql
max by (cluster) (elasticsearch_cluster_health_status{color="red"}) == 1
```

Reported by `elasticsearch-exporter` (`logging`) for ECK cluster `elasticsearch`: at least one **primary**
shard is unassigned. Topology (`gitops/platform/observability/elastic/manifests/elasticsearch.yaml`): nodeSets
`master` x3, `hot` x3 (ingest, 6Ti), `warm` x2 (12Ti), all on `longhorn-db` (1 Longhorn replica, strict-local).

Important: warm indices have **0 replicas** (ILM warm phase; immutable and snapshotted), so losing a warm node
or its volume turns the cluster red until the node returns or the indices are restored from snapshot.

## Impact

Writes to the affected data streams fail (Fluent Bit retries/buffers, APM Server rejects), and searches over
those indices return partial results. Logs `logs-<namespace>-k8s` and APM `traces-apm*` may be affected.

## Diagnosis

```bash
PW=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging port-forward svc/elasticsearch-es-http 9200 &
ES="curl -sk -u elastic:$PW https://localhost:9200"
$ES/_cluster/health?pretty
$ES/_cat/nodes?v\&h=name,node.role,heap.percent,disk.used_percent,master
$ES/_cat/shards?v\&h=index,shard,prirep,state,unassigned.reason,node | grep -v STARTED
$ES/_cluster/allocation/explain?pretty           # first unassigned shard, the reason
```

```bash
kubectl -n logging get elasticsearch elasticsearch        # HEALTH / PHASE from ECK
kubectl -n logging get pods -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch -o wide
kubectl -n logging get pvc | grep elasticsearch-data
kubectl -n elastic-system logs statefulset/elastic-operator --tail=100
```

Grafana: datasource *Elasticsearch Logs* / the exporter metrics (`elasticsearch_cluster_health_unassigned_shards`,
`elasticsearch_cluster_health_number_of_nodes`).

## Mitigation

1. Node down / pod pending: get the pod running again (node Ready, Longhorn volume attached —
   [LonghornVolumeDegraded](LonghornVolumeDegraded.md)). Shards recover automatically when the node rejoins.
2. Disk flood stage (95 %) / watermarks: [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md).
3. Allocation failed too many times (`max_retry` in allocation explain) after the cause is fixed:
   `$ES -XPOST '/_cluster/reroute?retry_failed=true'`.
4. Warm node volume lost (strict-local replica gone): restore the missing indices from the snapshot
   repository `minio-s3` (SLM `nightly-snapshots`, 01:30):
   `$ES/_snapshot/minio-s3/_all?verbose=false` → close/delete the red index → `_restore` it.
   Deleting an index requires its exact name (`action.destructive_requires_name: true`).
5. Hot-tier primary lost with no replica (should not happen, hot indices have 1 replica): accept data loss for
   that backing index only as a conscious decision (`allocate_empty_primary` via `_cluster/reroute`) and record it.
6. Never delete ECK-managed PVCs of running nodes; scale changes go through the `Elasticsearch` CR in Git.

## Escalation

On-call immediately; observability owners. Data-loss decisions (empty primary, restore) require the platform
lead's approval.

## Related

- [ElasticsearchClusterYellow](ElasticsearchClusterYellow.md), [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md),
  [ElasticsearchHeapHigh](ElasticsearchHeapHigh.md), [FluentBitOutputErrors](FluentBitOutputErrors.md)
- `gitops/platform/observability/elastic/manifests/es-bootstrap-job.yaml` (ILM, SLM, cluster settings)
