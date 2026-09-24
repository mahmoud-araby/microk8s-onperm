# ElasticsearchHeapHigh

## Severity

warning (`for: 15m`) — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.

## Meaning

```promql
max by (cluster, name) (elasticsearch_jvm_memory_used_bytes{area="heap"} / elasticsearch_jvm_memory_max_bytes{area="heap"}) > 0.90
```

JVM heap of node `{{ $labels.name }}` has stayed above 90 % for 15 minutes — the GC no longer reclaims enough
memory. Heap sizes (`ES_JAVA_OPTS`, 50 % of the container memory): `master` 4g (8Gi), `hot` 16g (32Gi),
`warm` 12g (24Gi). Hot nodes also run ingest with `thread_pool.write.queue_size: 2000` and
`indices.memory.index_buffer_size: 20%`.

## Impact

Long GC pauses (slow search and bulk indexing, node dropping out of the cluster), circuit breaker exceptions
(`CircuitBreakingException`, HTTP 429 to Fluent Bit / APM Server), and eventually OOM-kill of the pod
(cluster yellow/red). On a master, cluster-state updates stall.

## Diagnosis

```bash
PW=$(kubectl -n logging get secret elasticsearch-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
kubectl -n logging port-forward svc/elasticsearch-es-http 9200 &
ES="curl -sk -u elastic:$PW https://localhost:9200"
$ES/_cat/nodes?v\&h=name,node.role,heap.percent,ram.percent,cpu,segments.count
$ES/_nodes/stats/breaker?pretty | grep -E '"(name|tripped|estimated_size)"'
$ES/_nodes/stats/jvm?filter_path=nodes.*.name,nodes.*.jvm.gc
$ES/_cat/thread_pool/write,search?v\&h=node_name,name,active,queue,rejected
$ES/_nodes/hot_threads
$ES/_cat/shards?v\&h=index,shard,prirep,node,store | sort -k4 | awk '{print $4}' | uniq -c   # shards per node
$ES/_tasks?actions=*search*\&detailed\&pretty | head -60                               # heavy queries
```

```bash
kubectl -n logging get pods -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch   # restarts / OOMKilled
kubectl -n logging describe pod <pod> | grep -A3 'Last State'
```

```promql
rate(elasticsearch_jvm_gc_collection_seconds_sum[5m])
elasticsearch_breakers_tripped
```

Frequent causes: expensive Kibana / Grafana queries (large time ranges, high-cardinality aggregations on
`logs-*-k8s`), too many shards per node, bulk bursts after an outage (Fluent Bit replaying its buffer),
fielddata on text fields.

## Mitigation

1. Kill runaway searches: `$ES -XPOST '/_tasks/<task_id>/_cancel'`; ask users to narrow Kibana time ranges.
2. After an ingestion outage, the Fluent Bit backlog replay is transient — watch that heap decreases; if the
   node is OOM-looping, temporarily reduce Fluent Bit `Workers` or wait for rollover.
3. Too many shards (expected ~3,000 in total, 1 primary per backing index): look for unexpected data
   streams / indices and delete obsolete ones by exact name; check ILM deletes are running
   (`$ES/_ilm/explain/.ds-logs-*?only_errors=true`).
4. Restart only one node at a time and only if heap does not recover (`kubectl -n logging delete pod
   elasticsearch-es-hot-N`; ECK recreates it, wait for green/yellow before the next).
5. Structural: more memory/heap for the nodeSet (keep heap = 50 % of limit and < 31g) or add `hot` nodes, in
   `gitops/platform/observability/elastic/manifests/elasticsearch.yaml`.

## Escalation

`#platform-alerts`, observability owners. On-call if a node is OOM-looping or the cluster turns red.

## Related

- [ElasticsearchClusterRed](ElasticsearchClusterRed.md), [ElasticsearchClusterYellow](ElasticsearchClusterYellow.md),
  [FluentBitOutputErrors](FluentBitOutputErrors.md)
