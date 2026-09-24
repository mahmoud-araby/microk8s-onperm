# NodeUnderPressure

## Severity

warning (`for: 5m`) — `gitops/platform/observability/alerts/manifests/platform-rules.yaml`, group `platform.alerts`.
Routed to Slack `#platform-alerts` + e-mail.

## Meaning

The kubelet on `{{ $labels.node }}` reports a pressure condition (`MemoryPressure`, `DiskPressure` or
`PIDPressure`) from kube-state-metrics:

```promql
max by (node, condition) (kube_node_status_condition{condition=~"MemoryPressure|DiskPressure|PIDPressure", status="true"}) == 1
```

Thresholds come from the kubelet args set by Ansible
(`ansible/inventories/production/group_vars/all/microk8s.yml`, written to `/var/snap/microk8s/current/args/kubelet`):
`--eviction-soft memory.available<1Gi, nodefs.available<15%, imagefs.available<20%` (grace 1m30s/2m) and
`--eviction-hard memory.available<500Mi, nodefs.available<10%, nodefs.inodesFree<5%, imagefs.available<15%`.

## Impact

The node is tainted `node.kubernetes.io/<condition>` (no new pods) and the kubelet evicts pods, lowest
priority first (`batch-low`, `apps-default` before `platform-critical` / `data-critical`). On `data` /
`observability` nodes this can restart Postgres/Kafka/Elasticsearch members. If `DiskPressure` persists 15 min
`NodeDiskPressureCritical` fires.

## Diagnosis

1. Which node, which pool:
   ```bash
   kubectl get node <node> -L workload-tier,topology.kubernetes.io/zone
   kubectl describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
   kubectl get events -A --field-selector involvedObject.name=<node>,reason=EvictionThresholdMet
   kubectl get pods -A --field-selector spec.nodeName=<node>,status.phase=Failed   # evicted pods
   ```
2. Memory: `kubectl top node <node>` and
   ```bash
   kubectl top pods -A --sort-by=memory | head -20
   ```
   PromQL: `node_memory_MemAvailable_bytes{instance=~".*<node>.*"}`,
   `sum by (namespace, pod) (container_memory_working_set_bytes{node="<node>", container!=""})`.
3. Disk: see [NodeDiskPressureCritical](NodeDiskPressureCritical.md) (MicroK8s data dir `/var/snap/microk8s/common`, logs, images).
4. PIDs: `sum by (pod) (container_processes{node="<node>"})` (if cAdvisor exposes it) or on the host
   `ps -eLf | wc -l` and `cat /proc/sys/kernel/pid_max`.
5. Grafana: kube-prometheus-stack default dashboards *Node Exporter / Nodes* and
   *Kubernetes / Compute Resources / Node (Pods)*.

## Mitigation

1. Identify the offender (a pod without memory limits, a leaking app, a log-spamming container) and fix it in
   Git (limits in the chart values / tenant descriptor). As a stop-gap, delete or scale down the offending
   workload; for tenant workloads coordinate with the owning team.
2. Keep evicted pods from piling up: `kubectl delete pods -A --field-selector status.phase=Failed` (only
   removes already-evicted pod objects).
3. If the pool is simply full, cordon the node to stop new scheduling (`kubectl cordon <node>`) and add
   capacity: `ansible-playbook playbooks/add-node.yml` (see `ansible/README.md`), and review
   `docs/capacity-planning.md`.
4. Do **not** drain a `data` node with the last healthy replica of a Longhorn volume — Longhorn's
   `nodeDrainPolicy: block-for-eviction-if-contains-last-replica` will block it; check
   `kubectl -n longhorn-system get volumes.longhorn.io` first.

## Escalation

Platform on-call (`#platform-alerts`). If it is a `data` or `observability` node and stateful pods are being
evicted, involve the data team (`team=platform-data`) / observability owners.

## Related

- [NodeDiskPressureCritical](NodeDiskPressureCritical.md), [PlatformPVCFillingUp](PlatformPVCFillingUp.md), [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md)
- `docs/capacity-planning.md` (node pools), `docs/conventions.md` (workload tiers)
