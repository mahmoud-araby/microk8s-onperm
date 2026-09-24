# Data platform (`gitops/platform/data`)

Stateful services shared by all tenants: PostgreSQL (CloudNativePG), Redis + Sentinel, RabbitMQ,
Kafka (Strimzi, KRaft), WSO2 Micro Integrator, plus an optional SQL Server. Everything here is
deployed by Argo CD (project `data`) from the `*/application.yaml` files in this directory.

## Components and sync waves

| Dir | Application | Wave | Namespace | What |
|-----|-------------|------|-----------|------|
| `data-common/` | `data-common` | -10 | cluster | PriorityClass `data-critical` |
| `cnpg-operator/` | `cnpg-operator` | -10 | `cnpg-system` | CloudNativePG 1.30 (chart 0.29.1) + Barman Cloud plugin v0.15 (chart 0.8.0) |
| `rabbitmq-operator/` | `rabbitmq-operator` | -10 | `rabbitmq-system` | RabbitMQ cluster-operator 2.19.2 + messaging-topology-operator 1.20.3 (upstream manifests via kustomize) |
| `strimzi-operator/` | `strimzi-operator` | -10 | `data-kafka` | Strimzi 1.2.0 (chart), `kafka.strimzi.io/v1` API, Kafka 4.3.1 |
| `postgres/` | `postgres` | 0 | `data-postgres` | Cluster `pg-main`, poolers, databases, backups, alerts |
| `redis/` | `redis` | 0 | `data-redis` | Redis 7.4 (1 master + 2 replicas), Sentinel x3, HAProxy master router |
| `rabbitmq/` | `rabbitmq` | 0 | `data-rabbitmq` | RabbitmqCluster `rabbitmq` + topology (vhost, policies, exchanges, queues, users) |
| `kafka/` | `kafka` | 0 | `data-kafka` | Kafka `kafka` (3 controllers + 5 brokers), bridge, topics, users |
| `micro-integrator/` | `micro-integrator` | 0 | `integration` | WSO2 MI 4.4.0 (3-10 pods), legacy ERP mediation, inbound endpoints |
| `mssql/` | `mssql` (**disabled**) | 0 | `data-mssql` | Optional SQL Server 2022 (AG-ready StatefulSet) |

`examples/` folders (postgres, rabbitmq, kafka) are **not** synced: they hold manifests for the DR
site or optional features (replica cluster, federation/shovel, MirrorMaker 2, Debezium CDC).

Common rules applied to every data pod: `nodeSelector`/affinity `workload-tier=data` + toleration
`workload-tier=data:NoSchedule`, required anti-affinity on `kubernetes.io/hostname`, zone spread
(`topology.kubernetes.io/zone`, best effort), PriorityClass `data-critical`, PDBs, storage class
`longhorn-db` (1 Longhorn replica, `strict-local` - every engine replicates itself), metrics via
ServiceMonitor/PodMonitor + PrometheusRules, default-deny ingress NetworkPolicies, Istio sidecar
**disabled** for the stores (mesh clients reach them through auto-mTLS fallback; the engines use
their own auth/TLS). Micro Integrator is the exception: it runs **in** the mesh.

## Topology

```
                         tenant-* / shared-services / integration / keycloak / harbor / kong
                                                   |
     +--------------------+-------------------+----+-------------+-----------------------+
     |                    |                   |                  |                       |
 pg-main-pooler-rw   redis:6379          rabbitmq:5672   kafka-kafka-bootstrap:9092/9093  micro-integrator:8290
 (PgBouncer x3,      (HAProxy x3 ->      (3 nodes,        (5 brokers, 3 KRaft controllers, (MI x3..10, Istio,
  transaction mode)   current master)     quorum queues)   RF3/minISR2, rack aware)          -> ERP ServiceEntry)
     |                    |                                      |
 pg-main-rw/-ro      redis-node-0..2 <- redis-sentinel x3        +-- kafka-bridge-bridge-service:8080 (HTTP)
 (1 primary +        (AOF, replicaof)    (quorum 2, mymaster)    +-- external LB :9094 (internal-pool) -> hybrid consumers
  2 standbys, ANY 1 sync)
     |
 WAL archive + daily base backups -> MinIO (S3) --replicated--> DR site
```

## Connection endpoints (docs/conventions.md)

| Service | In-cluster endpoint | Auth | Notes |
|---------|---------------------|------|-------|
| PostgreSQL rw (PgBouncer) | `pg-main-pooler-rw.data-postgres.svc.cluster.local:5432` | SCRAM, `sslmode=require` | **default for apps**; transaction pooling |
| PostgreSQL ro (PgBouncer) | `pg-main-pooler-ro.data-postgres.svc.cluster.local:5432` | same | reads from standbys (replication lag!) |
| PostgreSQL rw / ro direct | `pg-main-rw.data-postgres.svc.cluster.local:5432` / `pg-main-ro...:5432` | same | Keycloak, Harbor, migrations, tenant role job, Debezium |
| Redis (master) | `redis.data-redis.svc.cluster.local:6379` | password | HAProxy routes to the node reporting `role:master` |
| Redis replicas | `redis-replicas.data-redis.svc.cluster.local:6379` | password | optional stale reads |
| Redis Sentinel | `redis-sentinel.data-redis.svc.cluster.local:26379`, master set `mymaster` | password (same) | Sentinel-aware clients |
| RabbitMQ AMQP / mgmt | `rabbitmq.data-rabbitmq.svc.cluster.local:5672` / `:15672` | user/password per vhost | UI: `https://rabbitmq.ops.example.local` |
| Kafka bootstrap | `kafka-kafka-bootstrap.data-kafka.svc.cluster.local:9092` (SASL_PLAINTEXT) / `:9093` (SASL_SSL) | **SCRAM-SHA-512** | ACLs enforced (`authorization: simple`) |
| Kafka external | `kafka-kafka-external-bootstrap` LoadBalancer (MetalLB `internal-pool`) `:9094`, cert SAN `kafka.internal.example.local` | SCRAM-SHA-512 + TLS | hybrid / on-prem consumers |
| Kafka HTTP bridge | `kafka-bridge-bridge-service.data-kafka.svc.cluster.local:8080` | none (network-restricted) | acts as KafkaUser `kafka-bridge` |
| Micro Integrator | `micro-integrator.integration.svc.cluster.local:8290` / `:8253` | mesh mTLS | `https://integration.internal.example.local` |
| SQL Server (optional) | `mssql.data-mssql.svc.cluster.local:1433` | SQL login | only when `mssql` is enabled |

Examples: `Host=pg-main-pooler-rw.data-postgres.svc.cluster.local;Port=5432;Database=acme_orders;Username=acme_orders;SSL Mode=Require` (.NET/Npgsql),
`jdbc:postgresql://pg-main-pooler-rw.data-postgres.svc.cluster.local:5432/acme_orders?sslmode=require&prepareThreshold=5` (Java),
`redis.data-redis.svc.cluster.local:6379,password=...,defaultDatabase=1,abortConnect=false` (StackExchange.Redis),
`amqp://acme-orders:...@rabbitmq.data-rabbitmq.svc.cluster.local:5672/acme`,
`bootstrap.servers=kafka-kafka-bootstrap.data-kafka.svc.cluster.local:9092`, `security.protocol=SASL_PLAINTEXT`, `sasl.mechanism=SCRAM-SHA-512`.

> **Kafka clients must authenticate.** All client listeners (9092/9093/9094) use SCRAM-SHA-512 so that the
> prefix ACLs of the tenant KafkaUsers are enforced. Services therefore need `KAFKA_SECURITY_PROTOCOL`
> `SASL_PLAINTEXT` (9092) or `SASL_SSL` (9093), `sasl.mechanism=SCRAM-SHA-512` and the user/password
> from Vault key `KAFKA_PASSWORD` (user `<tenant>-<service>`, created by charts/tenant).

## Capacity assumptions (1,000,000 users)

Aligned with `docs/capacity-planning.md`; validate with load tests before go-live.

| Metric | Assumption | Sizing consequence |
|--------|-----------|--------------------|
| Peak API traffic | ~15k RPS (headroom 30k), 80/20 read/write | - |
| Cache | >=60% of reads served by Redis, ~50-80k ops/s peak, 6-8 GB hot set | 1 Redis master, `maxmemory 12gb`, 16-20 GiB pods; Redis Cluster above ~100k ops/s |
| PostgreSQL | 3-5k TPS through PgBouncer, <400 GB data year 1, WAL 5-10 GB/h peak | 3 x 16 vCPU / 64 GiB, 500 GiB data + 150 GiB WAL, `max_connections=500`, 3 rw poolers x 140 server conns, 10k client conns |
| Kafka | 20k msgs/s avg, 50k msgs/s peak, 1 KB, RF 3, lz4 | 5 brokers x 6-8 vCPU / 32 GiB (8 GiB heap) / 1.5 TiB, 72 h default retention, 24 partitions on hot topics |
| RabbitMQ | ~5k msgs/s, bursts 15k/s, quorum queues | 3 x 4 vCPU / 12 GiB / 200 GiB, watermark 0.6, disk limit 10 GB |
| Micro Integrator | ~1.5k mediations/s per pod | 3-10 pods x 1-2 vCPU / 2.5 GiB (1.5 GiB heap) |
| Data nodes | 6 x 32 vCPU / 128 GiB / 2 x 2 TB NVMe, labelled `workload-tier=data` + `topology.kubernetes.io/zone` | total requests ~470 GiB RAM -> survives the loss of one node |

## Replication, backup and DR strategy

| Service | In-site HA (RPO / RTO) | Backups | Cross-site DR |
|---------|------------------------|---------|---------------|
| PostgreSQL | quorum sync replication `ANY 1` of 2 standbys (`minSyncReplicas: 1`, `maxSyncReplicas: 1`) -> RPO 0, automatic failover RTO ~10-30 s; replication slots survive failover | continuous WAL archive + daily base backup (`ScheduledBackup` 01:00 UTC) to MinIO via Barman Cloud plugin, 30 d PITR window; Longhorn snapshots + Velero as a second layer | replica cluster `pg-dr` (`postgres/examples/`) streaming over the interconnect with WAL-archive fallback (RPO seconds); promotion via `replica.primary` (demotion token for zero-loss switchover) |
| Redis | 2 async replicas, Sentinel quorum 2/3, failover ~5-10 s; `min-replicas-to-write 1` limits split-brain loss | AOF (fsync 1 s) + RDB snapshots on each node's PVC | cache: rebuilt on demand at the DR site (no replication); for session data use active-passive with `replicaof` over the WAN or RedisCluster + Redis Enterprise/Valkey tooling |
| RabbitMQ | quorum queues (Raft, 3 replicas), publisher confirms -> RPO 0 for confirmed messages; tolerates 1 node loss | definitions are GitOps (topology CRs); messages are transient by design | exchange federation from site A (DR pulls) and shovels for specific queues (`rabbitmq/examples/`) |
| Kafka | RF 3, `min.insync.replicas 2`, `acks=all`, rack-aware placement, unclean election off -> RPO 0, leader failover seconds | topic configs/users are GitOps; data retention is the "backup" (72 h - 30 d) | MirrorMaker 2 at the DR site (`kafka/examples/`), IdentityReplicationPolicy + offset sync -> consumers resume at DR |
| Micro Integrator | stateless, 3+ pods, HPA, PDB | artifacts in Git / image | redeploy from Git at the DR site |

Longhorn `longhorn-db` keeps a single local replica per volume (performance); the engines provide
redundancy. Longhorn recurring backups to the backup target still run as a coarse, engine-agnostic
safety net (core/longhorn), but restores should prefer engine-native backups (CNPG PITR, etc.).

## Per-tenant provisioning (charts/tenant)

The tenant chart renders objects **into the shared data namespaces** (all consumed by the operators
deployed here):

| Service | Objects created by charts/tenant | Isolation |
|---------|----------------------------------|-----------|
| PostgreSQL | `Database` CR `<tenant>_<db>` (cluster `pg-main`, `databaseReclaimPolicy: retain`) + owner role via a Sync-hook Job in `data-postgres` using secret `pg-main-superuser` | one database + one role per tenant service, `CONNECT` revoked from `PUBLIC`, per-role `connectionLimit` |
| Redis | nothing server-side | **logical DB index + key prefix** (see below) |
| RabbitMQ | `Vhost` `<tenant>`, `User` `<tenant>-<service>` (password from Vault), `Permission`, DLX policy | one vhost per tenant |
| Kafka | `KafkaTopic` `<tenant>.<name>`, `KafkaUser` `<tenant>-<service>` (SCRAM, prefix ACLs on `<tenant>.`) | topic/group/transactionalId prefix ACLs, quotas |

Large tenants (`tier: dedicated` with heavy load) can get their own CNPG `Cluster`, Redis and vhost
by copying the platform manifests into a tenant-specific directory.

### Redis tenant allocation

* DB index 0 = platform/shared (Kong rate limiting, shared-services); DB 1..63 = one per dedicated
  tenant, allocated in `gitops/tenants/<tenant>/tenant.yaml` (`data.redis.db`), `databases 64`.
* Every key is prefixed `<tenant>:<service>:` (`REDIS_KEY_PREFIX`), even inside a tenant DB - the
  prefix is the durable isolation mechanism because **Redis Cluster supports only DB 0**.
* Hardening option: Redis ACL users per tenant (`user acme on >pw ~acme:* &acme:* +@all -@admin -@dangerous`).

### Scale-out option: Redis Cluster (sharded)

When a single master exceeds ~100k ops/s or ~12 GB, move to Redis Cluster (e.g. 3 masters x 1
replica, 16384 hash slots): deploy 6 pods with `cluster-enabled yes` (or the OT-Container-Kit
`RedisCluster` CR), migrate keys per prefix (`redis-cli --cluster import`), and switch clients to
cluster mode (StackExchange.Redis / Lettuce / redis-py-cluster). Use hash tags (`{acme}:orders:...`)
for multi-key operations; DB indexes are no longer available (prefixes only). Valkey 8 (BSD) is a
drop-in alternative to Redis 7.4 (RSALv2/SSPL) / Redis 8 (AGPLv3 option) if licensing matters.

### Kafka alternative: Redpanda

Redpanda is a Kafka-API-compatible engine (C++, no JVM, Raft per partition) with lower tail latency
and fewer nodes for the same throughput. Clients, KafkaTopics semantics and MirrorMaker 2 keep
working; Strimzi CRs would be replaced by the Redpanda Operator (`Redpanda`, `Topic`, `User` CRs),
and the enterprise features (tiered storage, RBAC, Console SSO) require a Redpanda licence. Keep
Strimzi unless a benchmark shows Kafka cannot meet the latency SLOs on the available hardware.

## Vault secrets (KV v2 mount `secret`, ClusterSecretStore `vault-backend`)

| Path | Keys | Consumers |
|------|------|-----------|
| `secret/platform/postgres` | `superuser-password`, `platform-password` | `pg-main-superuser`, `pg-main-app-platform` |
| `secret/platform/postgres-backup` | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `ca.crt` | Barman Cloud plugin (MinIO) |
| `secret/platform/keycloak` / `secret/platform/harbor` | `db-password` | managed roles `keycloak` / `harbor` (and the Keycloak/Harbor deployments) |
| `secret/platform/redis` | `password` | Redis, Sentinel, HAProxy, apps, Kong |
| `secret/platform/rabbitmq` | `username`, `password`, `platform-app-password` | default admin user, user `platform-app` |
| `secret/platform/kafka` | `admin-password`, `bridge-password`, `platform-services-password`, `hybrid-consumer-password`, `mirrormaker2-password` | KafkaUsers |
| `secret/platform/micro-integrator` | `rabbitmq-password`, `kafka-password`, `erp-api-key` | MI + its RabbitMQ User / KafkaUser |
| `secret/platform/mssql` (optional) | `sa-password`, `ag-cert-password`, `ag-master-key-password` | SQL Server |
| `secret/tenants/<tenant>/<service>` | `DB_PASSWORD`, `RABBITMQ_PASSWORD`, `KAFKA_PASSWORD`, `REDIS_PASSWORD` | charts/tenant + charts/microservice |

Use alphanumeric passwords for Redis (it is embedded in `redis.conf`/`haproxy.cfg`).

## Optional SQL Server (`mssql/`)

For .NET workloads that genuinely need SQL Server (EF6/stored procedures, vendor products). It is
**disabled**: the Application is `mssql/application.yaml.disabled`, which the bootstrap glob
`*/application.yaml` ignores. Enable by renaming it (see the file header). The StatefulSet runs 3
HADR-enabled SQL Server 2022 instances with a mirroring endpoint on 5022; the AG is created once
with the scripts in `mssql/manifests/50-ag-bootstrap-configmap.yaml` (`CLUSTER_TYPE = NONE`, manual
failover; use an AG operator such as DH2i DxOperator for automatic failover). **Licensing**:
`ACCEPT_EULA=Y` accepts the Microsoft EULA; `MSSQL_PID=Developer` is non-production only -
production needs Standard/Enterprise per-core licences for every node that can run the pods.

## Runbooks

### Runbook: Postgres failover

Automatic: CNPG promotes the most advanced standby when the primary is unhealthy; `pg-main-rw` and
the rw pooler follow the new primary. Check with `kubectl cnpg status pg-main -n data-postgres`.
* Planned switchover (node maintenance): `kubectl cnpg promote pg-main pg-main-2 -n data-postgres`.
* Writes blocked (`PostgresNoSyncStandby`): both standbys are down and `minSyncReplicas: 1` keeps
  durability. Restore a standby (`kubectl cnpg status`, check PVC/node). Only as a conscious,
  temporary decision: set `minSyncReplicas: 0` in Git to accept writes without a sync standby.
* Lost standby volume (Longhorn `strict-local` replica gone with its node): delete the PVC + pod
  (`kubectl cnpg destroy pg-main <instance> -n data-postgres`); CNPG re-clones it from the primary.
* DR promotion: see `postgres/examples/pg-dr-replica-cluster.yaml` header.

### Runbook: Postgres backup

* `PostgresWALArchivingFailing`: check the plugin sidecar logs
  (`kubectl logs -n data-postgres pg-main-1 -c plugin-barman-cloud`), MinIO reachability/credentials,
  bucket quota. WAL accumulates on the WAL volume (150 GiB, `max_slot_wal_keep_size` 64 GB).
* On-demand backup: `kubectl cnpg backup pg-main -n data-postgres --method plugin --plugin-name barman-cloud.cloudnative-pg.io`.
* PITR: create a new Cluster (e.g. `pg-restore`) with `bootstrap.recovery.source: pg-main-archive`,
  `recoveryTarget.targetTime: "2026-09-24 10:15:00+00"` and an `externalClusters` entry using the
  plugin with `barmanObjectName: pg-main-backup`, `serverName: pg-main`; verify, then switch
  clients or copy data back. Never restore over the running `pg-main`.

### Runbook: Redis failover

Automatic: Sentinel (quorum 2) promotes a replica after 5 s; HAProxy marks the new master UP
within ~2 s and kills sessions on the old one; clients reconnect (`abortConnect=false` /
auto-reconnect). A restarting pod asks Sentinel for the master and rejoins as a replica.
* Manual failover: `kubectl -n data-redis exec redis-sentinel-0 -c sentinel -- sh -c 'redis-cli -p 26379 SENTINEL failover mymaster'`.
* `RedisNoMaster` with 2 masters (split brain after a partition): identify the Sentinel master
  (`SENTINEL get-master-addr-by-name mymaster`), then `REPLICAOF <master-host> 6379` on the other.
* Full restart of all pods: redis-node-0 becomes master if no Sentinel knows one (AOF on disk is
  preserved); verify data before reopening traffic.
* Password rotation: update Vault, wait for ESO (1 h or annotate the ExternalSecret with
  `force-sync`), then bump `platform.example.com/config-revision` on the StatefulSets/Deployment.

### Runbook: RabbitMQ

* Node down: quorum queues keep working with 2 of 3 nodes. Never delete a PVC of a live cluster
  member; if a node's disk is lost, `rabbitmq-queues shrink` / `grow` quorum membership after it rejoins.
* Memory/disk alarm: publishers are blocked. Scale consumers (KEDA on queue depth), purge or move
  poison messages from `*.dlq`, raise `persistence.storage` in Git (Longhorn expands online).
* Dead letters: inspect in the UI (`https://rabbitmq.ops.example.local`), fix the consumer, then
  shovel the DLQ back (`rabbitmqadmin` or a temporary `Shovel` CR).
* Rolling upgrade: bump `spec.image` in Git; the operator restarts one node at a time and waits
  for quorum queues to be in sync (PDB `maxUnavailable: 1`).

### Runbook: Kafka

* Broker down: partitions stay available (RF 3, minISR 2). `KafkaUnderMinIsrPartitions` means a
  second replica is missing - producers with `acks=all` fail: restore the broker first.
* Scale out: raise `KafkaNodePool/brokers.spec.replicas`; Cruise Control auto-rebalances
  (`autoRebalance: add-brokers`). Scale in: lower replicas; Cruise Control (`remove-brokers`)
  moves the partitions off the highest broker IDs first, Strimzi refuses to remove a non-empty broker.
* Disk filling: lower `retention.ms` of the largest topics (KafkaTopic CR), then add brokers/volumes.
* DR failover: stop producers at site A (if reachable), wait for MM2 lag ~0, switch clients'
  bootstrap to site B; consumer offsets are already translated by the checkpoint connector.
* Certificates: Strimzi renews cluster/clients CAs in the maintenance window (00:00-05:00 UTC).

### Runbook: Micro Integrator

* ERP unavailable: the `LegacyErpEP` circuit opens (HTTP 503 + `Retry-After`); RabbitMQ messages
  are requeued until `delivery-limit` (20) then land in `integration.inbound.dlq`; Kafka records are
  retried 3 times. After ERP recovery, replay the DLQ.
* Config change: edit the ConfigMaps in Git and bump `platform.example.com/config-revision`
  (artifacts are not hot-deployed).
* Kafka inbound endpoint inactive: the stock `wso2/wso2mi` image lacks the Kafka inbound connector;
  build `micro-integrator/image/Dockerfile` and point the Deployment to the Harbor image.
* Health: `kubectl -n integration port-forward deploy/micro-integrator 9201` then
  `curl localhost:9201/healthz` and `curl localhost:9201/metric-service/metrics`.
