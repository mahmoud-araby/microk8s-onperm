# ElasticsearchClusterYellow

## Severity

warning (`for: 15m`) — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.
Inhibited while `ElasticsearchClusterRed` fires for the same `cluster`.

## Meaning

```promql
max by (cluster) (elasticsearch_cluster_health_status{color="yellow"}) == 1
```

All primaries are assigned but at least one **replica** shard has been unassigned for 15 minutes. Hot-tier
indices (`logs-*-k8s`, `traces-apm*` backing indices before the warm phase) have 1 replica; warm indices have 0
replicas and therefore never cause yellow.

Typical causes: a `hot` node restarting / down (only 3 hot nodes, so replicas cannot be placed on the same
node as their primary), the low disk watermark (85 %) reached on the remaining nodes, shard allocation
awareness by zone (`zoneAwareness` on every nodeSet) with a zone missing, or an ECK rolling upgrade in progress
(`changeBudget maxUnavailable: 1`).

## Impact

No data unavailable, but no redundancy for the affected shards: one more node failure turns the cluster red.
Recovery traffic can slow ingest.

## Diagnosis

```bash
PW=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging port-forward svc/elasticsearch-es-http 9200 &
ES="curl -sk -u elastic:$PW https://localhost:9200"
$ES/_cluster/health?pretty                       # unassigned / initializing / relocating counts
$ES/_cat/shards?v\&h=index,shard,prirep,state,unassigned.reason | grep UNASSIGNED | head
$ES/_cluster/allocation/explain?pretty
$ES/_cat/allocation?v                            # disk per node
$ES/_cat/recovery?active_only=true\&v
```

```bash
kubectl -n logging get elasticsearch elasticsearch
kubectl -n logging get pods -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch -o wide
kubectl get nodes -l workload-tier=observability -L topology.kubernetes.io/zone
```

## Mitigation

1. Recovery in progress (`initializing_shards` > 0, `_cat/recovery` active): wait; it is expected after a node
   restart or during an ECK rolling change.
2. Node missing: bring it back (pod Pending → node / Longhorn issue). If a node will be gone for long, the
   cluster stays yellow by design — do not reduce replicas on hot indices unless decided by the owners.
3. Disk watermark: free space → [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md).
4. Allocation retries exhausted after the fix: `$ES -XPOST '/_cluster/reroute?retry_failed=true'`.
5. Zone awareness blocks placement (one zone down): acceptable temporarily; restore the zone's nodes.

## Escalation

`#platform-alerts`, observability owners. Escalate to on-call if it lasts > 2 h or a second node is at risk.

## Related

- [ElasticsearchClusterRed](ElasticsearchClusterRed.md), [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md),
  [NodeUnderPressure](NodeUnderPressure.md)
- `gitops/platform/observability/README.md` (Retention & sizing)
