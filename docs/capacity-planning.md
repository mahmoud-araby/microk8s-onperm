# Capacity Planning — 1,000,000 users

Numbers below are a **starting point**. Validate them with load tests (k6/Gatling) against your real
traffic mix before go-live and revisit quarterly.

## Workload assumptions

| Metric | Assumption |
|--------|-----------|
| Registered users | 1,000,000 |
| Daily active users | 30% → 300,000 |
| Peak concurrent users | 10% of registered → 100,000 |
| Requests per active user at peak | ~1 request / 7 s |
| **Peak API throughput** | **~15,000 RPS** (design headroom to 30,000 RPS) |
| Read / write ratio | 80 / 20 |
| Cache hit ratio target | ≥ 60% of reads served from Redis |
| Postgres TPS at peak | 3,000–5,000 (through PgBouncer) |
| Kafka ingest | ~20k msgs/s avg, 50k msgs/s peak, 1 KB avg |
| RabbitMQ | ~5k msgs/s, quorum queues |
| Log volume | ~1.5 TB/day raw at INFO (sampled access logs), ~30 days hot+warm |
| Traces | 10% baseline sampling + 100% of errors/slow (tail sampling) |

## Node pools

| Pool (`workload-tier`) | Count | Spec (per node) | Hosts |
|------------------------|-------|-----------------|-------|
| control plane (masters) | 3 | 8 vCPU, 32 GB, 200 GB SSD | dqlite voters, Argo CD, core controllers |
| `edge` | 3 | 16 vCPU, 32 GB | Kong, Istio ingress/internal gateways (tainted) |
| `platform` | 6 | 16 vCPU, 64 GB | Istio control plane, Keycloak, Vault, Harbor, operators |
| `data` | 6 | 32 vCPU, 128 GB, 2×2 TB NVMe | Postgres, Redis, RabbitMQ, Kafka (tainted) |
| `storage` | 4 | 16 vCPU, 64 GB, 4 × 8 TB NVMe | In-cluster MinIO tenant `minio` (tainted): 16 drives, EC:4 → 128 TB raw ≈ 96 TB usable; keep < 80 % full ([storage.md](storage.md)) |
| `apps` | 12 → 30 | 32 vCPU, 64 GB | Tenant workloads (cluster autoscaling = add nodes via Ansible `add-node.yml`) |
| `observability` | 10 | 5 × (16 vCPU, 64 GB, 2 TB NVMe) for Prometheus/Thanos/Kibana/APM/OTel + 3 × ES hot (32 vCPU, 128 GB, 8 TB NVMe) + 2 × ES warm (16 vCPU, 64 GB, 16 TB) | Elasticsearch, Prometheus, Thanos, Grafana, OTel |

Spread every pool across ≥ 3 racks / failure domains and label nodes with `topology.kubernetes.io/zone`.

## Per-service sizing (reference services)

| Service | Throughput share | Pod resources | Replicas (min / max) |
|---------|------------------|---------------|----------------------|
| orders (.NET) | 35% | 500m–2 CPU, 512 Mi–1 Gi | 6 / 60 |
| catalog (Python, gunicorn+uvicorn) | 45% | 500m–2 CPU, 512 Mi–1 Gi | 8 / 80 |
| payments (Java 21) | 10% (+ async) | 1–2 CPU, 1–2 Gi | 4 / 40 (KEDA on queue depth) |
| web (nginx) | static | 100m–500m, 128 Mi | 3 / 20 |

Rule of thumb: a well-written .NET/Java pod handles 800–1,500 RPS per CPU for simple I/O-bound endpoints;
Python async ~300–600 RPS per worker. Target 60–70% CPU at peak.

## Gateways

- Kong: ~10k RPS per 4-vCPU pod with JWT + rate limiting → 3 minimum, HPA to 20.
- Istio sidecar overhead: ~0.35 vCPU and 60 MB per 1,000 RPS; size sidecar requests accordingly
  (`sidecar.istio.io/proxyCPU`).

## Data tier

- **Postgres**: 16 vCPU / 64 GB primary, `max_connections=500`, PgBouncer transaction pooling in front
  (default_pool_size 50/db-user, max_client_conn 10,000). Add read replicas / route reads to `-ro`.
  Beyond ~10k TPS, shard by tenant (dedicated CNPG cluster per large tenant).
- **Redis**: 3 × 16 GB, `maxmemory 12gb`, `allkeys-lru`. Move to Redis Cluster (sharding) above ~100k ops/s.
- **Kafka**: 3 controllers + 5 brokers, RF=3, min.insync=2; 24 partitions for hot topics.
- **RabbitMQ**: 3 nodes, quorum queues, publisher confirms, lazy queues for backlogs.
- **Elasticsearch**: 3 masters, 3 hot (6 TiB NVMe each), 2 warm (12 TiB each) ≈ 42 TiB raw; hot indices keep 1 replica,
  warm indices none (read-only, covered by nightly snapshots). Set `vm.max_map_count=1048576` on these nodes.

## Scaling levers

1. HPA / KEDA on each service (CPU, RPS, queue depth, consumer lag).
2. Add `apps` nodes (`make` → `ansible/playbooks/add-node.yml`).
3. Split heavy tenants into dedicated namespaces/data clusters (tenant `tier: dedicated`).
4. Enable Redis Cluster and Postgres sharding per tenant.
5. Multi-cluster: second MicroK8s cluster in another site, Kafka MM2 + CNPG replica cluster + global DNS/GSLB.
