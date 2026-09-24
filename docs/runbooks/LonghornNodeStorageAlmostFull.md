# LonghornNodeStorageAlmostFull

## Severity

warning (`for: 15m`) — `gitops/platform/observability/alerts/manifests/platform-rules.yaml`.

## Meaning

```promql
(longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes) > 0.85
```

The Longhorn disk(s) of node `{{ $labels.node }}` (default data path `/var/lib/longhorn`, a dedicated
mount prepared by the Ansible `common` role) are more than 85 % used by replica data.

Relevant Longhorn settings (`gitops/platform/core/longhorn/values.yaml`):
`storageMinimalAvailablePercentage: 15` (no new replica is scheduled on a disk with less than 15 % free),
`storageReservedPercentageForDefaultDisk: 25`, `storageOverProvisioningPercentage: 150`.

## Impact

At ~85 % the disk stops accepting new replicas: new PVCs, volume expansions and replica rebuilds that target
this node fail. For `longhorn-db` (strict-local, 1 replica) the pod pinned to this node cannot grow its volume.
A physically full disk makes the volumes on it read-only / faulted.

## Diagnosis

```bash
kubectl -n longhorn-system get nodes.longhorn.io <node> -o jsonpath='{.status.diskStatus}' | jq
kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep <node>   # which volumes live there
kubectl get node <node> -L workload-tier
```

```promql
longhorn_disk_usage_bytes{node="<node>"} / longhorn_disk_capacity_bytes{node="<node>"}
sum by (volume) (longhorn_volume_actual_size_bytes)            # snapshots inflate actual size
topk(10, longhorn_volume_actual_size_bytes / longhorn_volume_capacity_bytes)
```

Longhorn UI (`kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80`) → Node → disk
*Scheduled* vs *Used*; Volume → Snapshots.

Also check the node's filesystem directly: `df -h /var/lib/longhorn` (SSH).

## Mitigation

1. Reclaim snapshot space (safe): snapshots are created by the RecurringJobs `snapshot-hourly` (retain 24,
   group `default-snapshots`) and `db-snapshot-6h` (retain 8, group `db-snapshots`); `snapshot-cleanup-daily`
   purges removed snapshots at 03:30. Trigger a purge / delete old snapshots of the largest volumes in the UI.
2. Remove orphaned replica data: `orphanResourceAutoDeletion: replica-data;instance` handles most; check
   `kubectl -n longhorn-system get orphans.longhorn.io`.
3. Rebalance `longhorn` (3-replica) volumes: disable scheduling on the full disk in the UI (Node → Edit
   disk → Scheduling disabled) and evict a few replicas; Longhorn rebuilds them on other nodes of the pool.
   Never evict the only replica of a `longhorn-db` volume.
4. Add capacity: attach a new disk and add it to the Longhorn node (UI or `nodes.longhorn.io` spec), or add a
   node to the pool (`playbooks/add-node.yml`). Longhorn creates default disks only on nodes labelled for it
   (`createDefaultDiskLabeledNodes: true`).
5. Reduce data: shorten application retention (Kafka `retention.ms`, ES ILM, Prometheus `retentionSize`).

## Escalation

Platform on-call via `#platform-alerts`. If the node carries `data` workloads, inform the data team before
moving replicas. Hardware procurement for new disks: platform lead.

## Related

- [LonghornVolumeDegraded](LonghornVolumeDegraded.md), [PlatformPVCFillingUp](PlatformPVCFillingUp.md)
- `docs/capacity-planning.md`, `gitops/platform/core/longhorn/manifests/recurringjobs.yaml`
