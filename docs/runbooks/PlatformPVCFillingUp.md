# PlatformPVCFillingUp

Also used by `PlatformPVCAlmostFull` and `PlatformPVCFillingUpPredicted`
(`gitops/platform/observability/alerts/manifests/platform-rules.yaml`).

## Severity

| Alert | Severity | Condition | `for` |
|---|---|---|---|
| `PlatformPVCFillingUpPredicted` | warning | < 40 % free and `predict_linear(...[6h], 4d) < 0` | 1h |
| `PlatformPVCFillingUp` | warning | < 15 % free (ReadOnlyMany PVCs excluded) | 10m |
| `PlatformPVCAlmostFull` | critical | < 5 % free | 5m |

## Meaning

Kubelet volume stats for a mounted PVC (`namespace`, `persistentvolumeclaim` labels):

```promql
kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.15
  and kubelet_volume_stats_used_bytes > 0
  unless on (namespace, persistentvolumeclaim) kube_persistentvolumeclaim_access_mode{access_mode="ReadOnlyMany"} == 1
```

All PVCs are Longhorn: `longhorn` (3 replicas, ext4, `reclaimPolicy: Delete`) or `longhorn-db` (1 replica,
strict-local, xfs, `reclaimPolicy: Retain`). Both have `allowVolumeExpansion: true` (online expansion).

## Impact

A full volume makes the workload fail writes: Postgres stops (`data-postgres`), Kafka brokers go offline
(`data-kafka`), RabbitMQ raises a disk alarm and blocks publishers, Prometheus stops ingesting
(`monitoring`, 500Gi `longhorn-db`), Elasticsearch hits flood stage and indices turn read-only.

## Diagnosis

```bash
kubectl -n <namespace> get pvc <pvc> -o wide
kubectl -n <namespace> describe pvc <pvc> | grep -E 'StorageClass|Capacity|Used By'
kubectl -n longhorn-system get volumes.longhorn.io $(kubectl -n <namespace> get pvc <pvc> -o jsonpath='{.spec.volumeName}')
```

```promql
kubelet_volume_stats_used_bytes{namespace="<ns>", persistentvolumeclaim="<pvc>"}
predict_linear(kubelet_volume_stats_available_bytes{namespace="<ns>", persistentvolumeclaim="<pvc>"}[6h], 24*3600)
```

Grafana: kube-prometheus-stack dashboard *Kubernetes / Persistent Volumes*; data PVCs also on
**Data Services Summary** (e.g. *Database size*). Check what is growing inside the pod
(`kubectl exec ... -- df -h` / `du`), e.g. Postgres WAL (`PostgresWALArchivingFailing`), Kafka retention,
RabbitMQ backlog, Prometheus TSDB.

Before expanding, confirm the Longhorn node has room: [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md).

## Mitigation

1. Remove the cause if it is abnormal growth: failing WAL archiving (Postgres backup runbook), a queue
   without consumers, a Kafka topic with too long `retention.ms`, Prometheus `retentionSize` too high.
2. Expand the volume **in Git** so Argo CD does not revert it:
   - CNPG `pg-main`: `spec.storage.size` / `spec.walStorage.size` in `gitops/platform/data/postgres/manifests/20-cluster.yaml`.
   - Strimzi: storage of `KafkaNodePool` `brokers` in `gitops/platform/data/kafka/manifests/20-kafka.yaml`.
   - RabbitMQ: `persistence.storage` (200Gi) in `gitops/platform/data/rabbitmq/manifests/10-rabbitmqcluster.yaml`.
   - Elasticsearch: `volumeClaimTemplates` storage of the nodeSet in `gitops/platform/observability/elastic/manifests/elasticsearch.yaml` (ECK resizes the PVCs).
   - Prometheus: `storageSpec` in `kube-prometheus-stack/values.yaml` **and** patch the existing PVCs
     (StatefulSet claim templates are immutable):
     `kubectl -n monitoring patch pvc <pvc> -p '{"spec":{"resources":{"requests":{"storage":"700Gi"}}}}'`.
   - Plain StatefulSets / tenant PVCs: patch the PVC the same way, then persist the size in the chart values.
3. Watch Longhorn expand online: `kubectl -n longhorn-system get volumes.longhorn.io <pv> -w`; the
   filesystem grows once the engine finishes (`kubectl -n <ns> get pvc <pvc>` shows new capacity).
4. `PlatformPVCAlmostFull` on a database: act immediately (expand first, investigate after).

## Escalation

Warning → `#platform-alerts`; critical → on-call. Data namespaces (`data-*`): data team
(`team=platform-data`). Tenant PVCs: the tenant's owning team via `#tenant-<t>-alerts`.

## Related

- [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md), [LonghornVolumeDegraded](LonghornVolumeDegraded.md)
- [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md)
- `gitops/platform/data/README.md` (Postgres backup, Kafka and RabbitMQ runbooks)
