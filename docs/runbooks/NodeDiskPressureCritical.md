# NodeDiskPressureCritical

## Severity

critical (`for: 15m`) — `gitops/platform/observability/alerts/manifests/platform-rules.yaml`.
Pages on-call (PagerDuty) + Slack. `NodeUnderPressure` (warning) fires for the same node as well.

## Meaning

```promql
max by (node) (kube_node_status_condition{condition="DiskPressure", status="true"}) == 1
```

The node has reported `DiskPressure` for 15 minutes: image garbage collection
(`--image-gc-high-threshold 80` / `--image-gc-low-threshold 70`) and pod eviction did not bring the
filesystem back under the kubelet thresholds (`nodefs.available<10%`, `nodefs.inodesFree<5%`,
`imagefs.available<15%` hard). On MicroK8s both nodefs and imagefs live under
`/var/snap/microk8s/common` (kubelet root `var/lib/kubelet`, containerd `var/lib/containerd`), usually on
the root filesystem. Longhorn data is on its own mount `/var/lib/longhorn` and is **not** part of nodefs.

## Impact

Continuous evictions on the node, new pods cannot start there, image pulls fail. Control-plane nodes
(`prd-master-0x`) with a full disk also put dqlite (`k8s-dqlite`) at risk — treat as urgent.

## Diagnosis

```bash
kubectl describe node <node> | grep -A8 Conditions
kubectl get pods -A --field-selector spec.nodeName=<node> -o wide | grep -Ei 'evicted|error'
```

PromQL (node-exporter):

```promql
node_filesystem_avail_bytes{instance=~".*<node>.*", fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes
node_filesystem_files_free{instance=~".*<node>.*", mountpoint="/"}
```

On the host (SSH as `ansible`):

```bash
df -h / /var/snap/microk8s/common /var/lib/longhorn; df -i /
sudo du -xh --max-depth=2 /var/snap/microk8s/common/var/lib | sort -h | tail
sudo du -xsh /var/log/pods /var/log/containers /var/log/journal
sudo microk8s ctr images ls -q | wc -l
sudo du -xh --max-depth=1 /var/snap/microk8s/common/var/lib/kubelet/pods | sort -h | tail   # emptyDir
```

Kibana: host logs of `kubelite` / `containerd` are in data stream `logs-node-k8s` (query
`node : "<node>" and message : *eviction*`).

## Mitigation

1. Safe first: remove unused images — `sudo microk8s ctr images rm <ref>` for old tags (images in use are
   protected), and delete already-evicted pod objects:
   `kubectl delete pods -A --field-selector spec.nodeName=<node>,status.phase=Failed`.
2. Trim journald if it grew beyond the managed limit (`SystemMaxUse=2G`, role `common`):
   `sudo journalctl --vacuum-size=1G`.
3. Find a pod writing heavily to `emptyDir` or container logs (log rotation is `--container-log-max-size 50Mi`,
   5 files) and fix it at the source; set `ephemeral-storage` limits in its chart values.
4. Fluent Bit filesystem buffer (host path `/var/lib/fluent-bit`, up to 8 GiB for container logs) grows when Elasticsearch is
   unreachable — fix Elasticsearch ([FluentBitOutputErrors](FluentBitOutputErrors.md)) rather than deleting the buffer (log loss).
5. Cordon the node (`kubectl cordon <node>`) while cleaning; uncordon when `DiskPressure` clears.
6. Structural fix: grow the root disk / move `/var/snap/microk8s/common` to a larger volume via the
   Ansible roles (`ansible/README.md`), then re-run `playbooks/prepare-nodes.yml` for that host.

## Escalation

Platform on-call. For control-plane nodes also check the other masters (inventory group `microk8s_masters`,
`prd-master-01..03`) and escalate to the platform lead if more than one master is affected (dqlite quorum).

## Related

- [NodeUnderPressure](NodeUnderPressure.md), [PlatformPVCFillingUp](PlatformPVCFillingUp.md), [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md)
- `ansible/inventories/production/group_vars/all/microk8s.yml` (kubelet eviction / GC args)
