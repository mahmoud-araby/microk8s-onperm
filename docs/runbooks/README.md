# Runbooks

Operator runbooks for the platform alerts. Every `PrometheusRule` alert carries
`runbook_url: https://github.com/mahmoud-araby/microk8s-onperm/blob/main/docs/runbooks/<Name>.md`; several
related alerts share one runbook. Routing (`kube-prometheus-stack/values.yaml`): **critical** → PagerDuty
(`oncall-critical`) + Slack, **warning** → Slack `#platform-alerts` + e-mail, `tenant=<t>` → also
`#tenant-<t>-alerts`. Names, namespaces and endpoints follow [`docs/conventions.md`](../conventions.md).

Each runbook: Severity · Meaning (the real PromQL) · Impact · Diagnosis · Mitigation (safe first) ·
Escalation · Related.

## Platform, edge and observability alerts

Rules in `gitops/platform/observability/alerts/manifests/` (namespace `monitoring`).

| Alert | Severity | Component | Runbook |
|---|---|---|---|
| `SLOAvailabilityBudgetBurnFast` | critical | SLO (Istio, every mesh service) | [SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md) |
| `SLOAvailabilityBudgetBurnSlow` | warning | SLO (Istio, every mesh service) | [SLOAvailabilityBudgetBurn](SLOAvailabilityBudgetBurn.md) |
| `SLOLatencyBudgetBurnFast` | critical | SLO (Istio, every mesh service) | [SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md) |
| `SLOLatencyBudgetBurnSlow` | warning | SLO (Istio, every mesh service) | [SLOLatencyBudgetBurn](SLOLatencyBudgetBurn.md) |
| `NodeUnderPressure` | warning | Nodes (kubelet) | [NodeUnderPressure](NodeUnderPressure.md) |
| `NodeDiskPressureCritical` | critical | Nodes (kubelet, MicroK8s) | [NodeDiskPressureCritical](NodeDiskPressureCritical.md) |
| `PlatformPVCFillingUp` | warning | Storage (PVC) | [PlatformPVCFillingUp](PlatformPVCFillingUp.md) |
| `PlatformPVCAlmostFull` | critical | Storage (PVC) | [PlatformPVCFillingUp](PlatformPVCFillingUp.md) |
| `PlatformPVCFillingUpPredicted` | warning | Storage (PVC) | [PlatformPVCFillingUp](PlatformPVCFillingUp.md) |
| `LonghornVolumeDegraded` | warning | Longhorn (`longhorn-system`) | [LonghornVolumeDegraded](LonghornVolumeDegraded.md) |
| `LonghornVolumeFaulted` | critical | Longhorn (`longhorn-system`) | [LonghornVolumeDegraded](LonghornVolumeDegraded.md) |
| `LonghornNodeStorageAlmostFull` | warning | Longhorn (`longhorn-system`) | [LonghornNodeStorageAlmostFull](LonghornNodeStorageAlmostFull.md) |
| `CertificateExpiringSoon` | warning | cert-manager | [CertificateExpiringSoon](CertificateExpiringSoon.md) |
| `CertificateExpiryCritical` | critical | cert-manager | [CertificateExpiringSoon](CertificateExpiringSoon.md) |
| `CertificateNotReady` | warning | cert-manager | [CertificateExpiringSoon](CertificateExpiringSoon.md) |
| `TLSEndpointCertificateExpiring` | warning | Blackbox exporter (live TLS) | [CertificateExpiringSoon](CertificateExpiringSoon.md) |
| `ArgoCDAppDegraded` | warning | Argo CD (`argocd`) | [ArgoCDAppDegraded](ArgoCDAppDegraded.md) |
| `ArgoCDAppMissing` | warning | Argo CD (`argocd`) | [ArgoCDAppDegraded](ArgoCDAppDegraded.md) |
| `ArgoCDAppOutOfSync` | warning | Argo CD (`argocd`) | [ArgoCDAppOutOfSync](ArgoCDAppOutOfSync.md) |
| `ArgoCDAppSyncFailed` | warning | Argo CD (`argocd`) | [ArgoCDAppOutOfSync](ArgoCDAppOutOfSync.md) |
| `RolloutAborted` | warning | Argo Rollouts | [RolloutAborted](RolloutAborted.md) |
| `RolloutAnalysisFailed` | warning | Argo Rollouts | [RolloutAborted](RolloutAborted.md) |
| `Kong5xxSurge` | critical | Kong (`kong`) | [Kong5xxSurge](Kong5xxSurge.md) |
| `KongGlobal5xxRateHigh` | warning | Kong (`kong`) | [Kong5xxSurge](Kong5xxSurge.md) |
| `KongLatencyHigh` | warning | Kong (`kong`) | [KongLatencyHigh](KongLatencyHigh.md) |
| `SyntheticProbeFailed` | critical | Blackbox probes (public) | [SyntheticProbeFailed](SyntheticProbeFailed.md) |
| `SyntheticProbeFailedInternal` | warning | Blackbox probes (ops / in-cluster) | [SyntheticProbeFailed](SyntheticProbeFailed.md) |
| `SyntheticProbeSlow` | warning | Blackbox probes (public) | [SyntheticProbeFailed](SyntheticProbeFailed.md) |
| `ElasticsearchClusterRed` | critical | Elasticsearch (`logging`) | [ElasticsearchClusterRed](ElasticsearchClusterRed.md) |
| `ElasticsearchClusterYellow` | warning | Elasticsearch (`logging`) | [ElasticsearchClusterYellow](ElasticsearchClusterYellow.md) |
| `ElasticsearchDiskWatermark` | warning | Elasticsearch (`logging`) | [ElasticsearchDiskWatermark](ElasticsearchDiskWatermark.md) |
| `ElasticsearchHeapHigh` | warning | Elasticsearch (`logging`) | [ElasticsearchHeapHigh](ElasticsearchHeapHigh.md) |
| `ElasticsearchExporterDown` | warning | Elasticsearch exporter (`logging`) | [ElasticsearchExporterDown](ElasticsearchExporterDown.md) |
| `FluentBitOutputErrors` | warning | Fluent Bit (`logging`) | [FluentBitOutputErrors](FluentBitOutputErrors.md) |
| `FluentBitRetriesExhausted` | critical | Fluent Bit (`logging`) | [FluentBitOutputErrors](FluentBitOutputErrors.md) |
| `FluentBitDroppedRecords` | critical | Fluent Bit (`logging`) | [FluentBitOutputErrors](FluentBitOutputErrors.md) |
| `OTelCollectorDroppingSpans` | warning | OTel collectors `otel` / `otel-sampler` (`observability`) | [OTelCollectorDroppingSpans](OTelCollectorDroppingSpans.md) |
| `OTelCollectorQueueFull` | critical | OTel collectors (`observability`) | [OTelCollectorDroppingSpans](OTelCollectorDroppingSpans.md) |
| `OTelCollectorEnqueueFailed` | critical | OTel collectors (`observability`) | [OTelCollectorDroppingSpans](OTelCollectorDroppingSpans.md) |
| `OTelCollectorRefusingData` | warning | OTel collectors (`observability`) | [OTelCollectorDroppingSpans](OTelCollectorDroppingSpans.md) |
| `ThanosCompactHalted` | critical | Thanos compactor (`monitoring`) | [ThanosCompactHalted](ThanosCompactHalted.md) |
| `ThanosSidecarUploadFailing` | warning | Thanos sidecar / Prometheus (`monitoring`) | [ThanosSidecarUploadFailing](ThanosSidecarUploadFailing.md) |

## Per-service alerts (`charts/microservice`)

Rendered per release `<service>-<version>` in its namespace; the prefix is the CamelCase release name (e.g.
`OrdersV1HighErrorRate`).

| Alert | Severity | Component | Runbook |
|---|---|---|---|
| `<Service>HighErrorRate` | critical | Service release (Istio) | [high-error-rate](high-error-rate.md#higherrorrate) |
| `<Service>HighLatencyP95` | warning | Service release (Istio) | [high-error-rate](high-error-rate.md#highlatencyp95) |
| `<Service>PodRestarts` | warning | Service release (pods) | [high-error-rate](high-error-rate.md#podrestarts) |
| `<Service>CircuitBreakerOpen` | warning | Service release (Istio outlier detection) | [high-error-rate](high-error-rate.md#circuitbreakeropen) |
| `<Service>AutoscalerAtMax` | warning | Service release (HPA / KEDA) | [high-error-rate](high-error-rate.md#autoscaleratmax) |
| `<Service>RolloutDegraded` | critical | Service release (Argo Rollouts) | [high-error-rate](high-error-rate.md#rolloutdegraded) |

`charts/frontend` renders similar `<Release>Frontend*` alerts without a `runbook_url`; use the same sections.

## Data-service alerts

Owned next to each data service (`gitops/platform/data/*/manifests/*monitoring*.yaml`, label
`team: platform-data`); the runbooks live in [`gitops/platform/data/README.md`](../../gitops/platform/data/README.md#runbooks).

| Alerts | Severity | Component | Runbook |
|---|---|---|---|
| `PostgresInstanceDown`, `PostgresNoSyncStandby`, `PgBouncerDown`, `PgBouncerMaxWaitHigh`, `PostgresXIDWraparoundRisk`, `PostgresVolumeFillingUp` | critical | CloudNativePG `pg-main` (`data-postgres`) | [Postgres failover](../../gitops/platform/data/README.md#runbook-postgres-failover) |
| `PostgresNotEnoughStandbys`, `PostgresReplicationLagHigh`, `PostgresConnectionsNearLimit`, `PgBouncerClientsWaiting` | warning | CloudNativePG `pg-main` (`data-postgres`) | [Postgres failover](../../gitops/platform/data/README.md#runbook-postgres-failover) |
| `PostgresWALArchivingFailing`, `PostgresBackupTooOld` | critical | CNPG backups (barman-cloud) | [Postgres backup](../../gitops/platform/data/README.md#runbook-postgres-backup) |
| `RedisDown`, `RedisNoMaster`, `RedisReplicationBroken`, `RedisRejectedConnections`, `RedisAOFWriteFailing`, `RedisMasterRouterNoBackend` | critical | Redis + Sentinel + HAProxy (`data-redis`) | [Redis failover](../../gitops/platform/data/README.md#runbook-redis-failover) |
| `RedisMissingReplicas`, `RedisMemoryHigh`, `RedisHighEvictionRate`, `RedisSentinelQuorumAtRisk` | warning | Redis (`data-redis`) | [Redis failover](../../gitops/platform/data/README.md#runbook-redis-failover) |
| `RabbitMQNodeDown`, `RabbitMQMemoryAlarm`, `RabbitMQDiskAlarm` | critical | RabbitMQ (`data-rabbitmq`) | [RabbitMQ](../../gitops/platform/data/README.md#runbook-rabbitmq) |
| `RabbitMQFileDescriptorsNearLimit`, `RabbitMQUnroutableMessages`, `RabbitMQHighConnectionChurn`, `RabbitMQQueueBacklog`, `RabbitMQQueueWithoutConsumers`, `RabbitMQDeadLetters` | warning | RabbitMQ (`data-rabbitmq`) | [RabbitMQ](../../gitops/platform/data/README.md#runbook-rabbitmq) |
| `KafkaBrokerDown`, `KafkaUnderMinIsrPartitions`, `KafkaOfflinePartitions`, `KafkaNoActiveController` | critical | Strimzi Kafka (`data-kafka`) | [Kafka](../../gitops/platform/data/README.md#runbook-kafka) |
| `KafkaUnderReplicatedPartitions`, `KafkaDiskFillingUp`, `KafkaConsumerGroupLagHigh`, `KafkaBridgeDown` | warning | Strimzi Kafka (`data-kafka`) | [Kafka](../../gitops/platform/data/README.md#runbook-kafka) |
| `MicroIntegratorDown` | critical | WSO2 Micro Integrator (`integration`) | [Micro Integrator](../../gitops/platform/data/README.md#runbook-micro-integrator) |
| `MicroIntegratorApiErrorRateHigh`, `MicroIntegratorApiLatencyHigh`, `MicroIntegratorInboundErrors` | warning | WSO2 Micro Integrator (`integration`) | [Micro Integrator](../../gitops/platform/data/README.md#runbook-micro-integrator) |
| `MSSQLDown`, `MSSQLNoPrimaryEndpoint` (critical), `MSSQLDeadlocks` (warning) | mixed | Optional SQL Server (`mssql/`) | [Optional SQL Server](../../gitops/platform/data/README.md#optional-sql-server-mssql) |

Storage alerts for data volumes (`PlatformPVC*`, `Longhorn*`) use the platform runbooks above.

## Useful entry points

| What | Where |
|---|---|
| Grafana dashboards | `https://grafana.ops.example.local`: *Platform Overview & SLOs* (`/d/platform-overview`), *Kong API Gateway* (`/d/kong-gateway`), *Microservice RED* (`/d/microservice-red`), *Circuit Breakers & Retries* (`/d/circuit-breakers`), *Data Services Summary* (`/d/data-services`), Fluent Bit, kube-prometheus-stack defaults |
| Logs / traces | Kibana `https://kibana.ops.example.local`: data view `logs-*-k8s` (field `kubernetes.namespace_name`, `trace_id`, `tenant`), APM (`traces-apm*`) |
| GitOps / delivery | `https://argocd.ops.example.local`, `https://rollouts.ops.example.local` |
| Prometheus / Alertmanager | `kube-prometheus-stack-prometheus.monitoring:9090`, `kube-prometheus-stack-alertmanager.monitoring:9093`, long range `thanos-query-frontend.monitoring:9090` |
