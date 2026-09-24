# LonghornVolumeDegraded

Also used by `LonghornVolumeFaulted` (`gitops/platform/observability/alerts/manifests/platform-rules.yaml`).

## Severity

| Alert | Severity | Expression | `for` |
|---|---|---|---|
| `LonghornVolumeDegraded` | warning | `max by (volume, pvc, pvc_namespace) (longhorn_volume_robustness) == 2` | 10m |
| `LonghornVolumeFaulted` | critical | `... (longhorn_volume_robustness) == 3` | 2m |

## Meaning

`longhorn_volume_robustness`: 1 = healthy, 2 = degraded (fewer healthy replicas than
`numberOfReplicas`, Longhorn is rebuilding), 3 = faulted (no healthy replica, data unavailable).

- StorageClass `longhorn` has 3 replicas (`replicaSoftAntiAffinity: false` → never two on one node,
  zone soft anti-affinity). Degraded = one or two replicas lost.
- StorageClass `longhorn-db` has **1 replica, strict-local** (Postgres, Kafka, RabbitMQ, Redis,
  Elasticsearch, Prometheus): it never rebuilds elsewhere — losing that replica means **Faulted**, and the
  application's own replication (CNPG standby, Kafka RF 3, ES replicas, Prometheus HA pair) is the redundancy.

## Impact

Degraded: no data loss yet, but reduced redundancy and extra I/O from the rebuild
(`concurrentReplicaRebuildPerNodeLimit: 2`). Faulted: the pod using the PVC cannot run / gets I/O errors.

## Diagnosis

```bash
kubectl -n longhorn-system get volumes.longhorn.io <volume> -o wide
kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=<volume> -o wide
kubectl -n longhorn-system get nodes.longhorn.io        # Ready / Schedulable / disk status
kubectl get nodes -L workload-tier,topology.kubernetes.io/zone
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=200 | grep <volume>
```

Longhorn UI (no ingress by design): `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`
→ Volume → replicas, rebuild progress, events.

```promql
longhorn_volume_robustness{volume="<volume>"}
longhorn_node_status{condition="ready"} == 0
longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes
```

Typical causes: node down / rebooted (see `KubeNodeNotReady`), disk full on the node
(`LonghornNodeStorageAlmostFull`), iSCSI/multipath problems on the host, network partition.

## Mitigation

1. Degraded with a node that is coming back: wait — Longhorn reuses the existing replica
   (`fastReplicaRebuildEnabled`) and `replicaAutoBalance: best-effort` rebalances. Watch the rebuild in the UI.
2. Node permanently gone: remove it properly (`ansible-playbook playbooks/remove-node.yml -e node=<host>`,
   which requests Longhorn replica eviction first); Longhorn rebuilds on the remaining nodes if space allows.
3. No schedulable space: free/extend disks first ([LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md)).
4. Faulted, `longhorn` class: `autoSalvage: true` normally recovers when a replica's node returns. If not,
   scale the workload to 0, salvage in the UI (Volume → Salvage), then scale up. Last resort: restore from the
   Longhorn backup (`backup-daily` / `backup-weekly` to `s3://longhorn-backups`) or Velero (tenant namespaces,
   hourly).
5. Faulted, `longhorn-db` class: do not try to salvage a lost disk — let the application re-seed:
   Postgres `kubectl cnpg destroy pg-main <instance> -n data-postgres` (re-clone from primary), Kafka/ES/RabbitMQ
   member: delete the PVC + pod so the operator recreates and resyncs it (see data runbooks). `reclaimPolicy:
   Retain` keeps the PV object — clean up the released PV afterwards.

## Escalation

Warning → `#platform-alerts`. Faulted → on-call immediately; involve the data team for `data-*` volumes and
the owning tenant team for tenant PVCs (restore decisions).

## Related

- [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md), [PlatformPVCFillingUp](PlatformPVCFillingUp.md), [NodeUnderPressure](NodeUnderPressure.md)
- `gitops/platform/core/longhorn/values.yaml`, `gitops/platform/core/README.md#disaster-recovery`
- `gitops/platform/data/README.md#runbook-postgres-failover`
