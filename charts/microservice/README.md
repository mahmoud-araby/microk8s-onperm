# microservice chart

Generic Helm chart for the platform's .NET, Java and Python services. One release = one **major API
version** of one service: the release (and every resource) is named `<service.name>-<service.version>`
(`orders-v1`, `orders-v2`), so several versions run side by side in the same namespace.

The values interface is the binding contract in [`docs/chart-interfaces.md`](../../docs/chart-interfaces.md);
naming, labels, endpoints and env vars follow [`docs/conventions.md`](../../docs/conventions.md).
Keys marked `(extra)` in `values.yaml` are chart additions. They do not change the interface.

## What gets rendered

| Resource | When | Notes |
|----------|------|-------|
| `Rollout` (argoproj.io/v1alpha1) | `rollout.enabled` | Canary with Istio traffic routing (VirtualService `<fullname>`, route `primary`, services `<fullname>` / `<fullname>-canary`), steps from values, background `AnalysisTemplate` |
| `Deployment` | `!rollout.enabled` | `RollingUpdate` maxSurge 25% / maxUnavailable 0 |
| `Service` `<fullname>` + `<fullname>-canary` | always / rollout | port 80 `http` → 8080, `appProtocol: http`; stable Service carries the Kong `service-upstream` and `host-header` annotations |
| `Service` `<fullname>-metrics` (headless) + `ServiceMonitor` | `serviceMonitor.enabled` | scrapes every pod exactly once, including canary pods; adds `version`, `role`, tenant labels |
| `ConfigMap` `<fullname>-config` | always | from `config`, loaded via `envFrom`; checksum on the pod template |
| `ExternalSecret` → Secret `<fullname>-secrets` | `externalSecret.enabled` | `external-secrets.io/v1` (ESO ≥ 0.17), ClusterSecretStore `vault-backend`, `dataFrom.extract` of `tenants/<tenant or shared>/<service>` |
| `VirtualService`, 2× `DestinationRule`, `AuthorizationPolicy` | `istio.enabled` | timeouts, retries, connection pool, outlier detection, `ISTIO_MUTUAL`, ALLOW policy |
| `AnalysisTemplate` | rollout + analysis + istio | success rate and p95 of `<fullname>-canary` from Istio metrics |
| `Ingress` (class `kong`) + `KongPlugin`s | `kong.enabled` | jwt, rate-limiting (Redis), correlation-id, request-transformer (tenant), response-transformer, prometheus, opentelemetry |
| `HorizontalPodAutoscaler` | `hpa.enabled && !keda.enabled` | targets the Rollout or the Deployment |
| `ScaledObject` (+ `TriggerAuthentication`) | `keda.enabled` | replaces the HPA |
| `PodDisruptionBudget` | `pdb.enabled` and min replicas > 1 | `unhealthyPodEvictionPolicy: AlwaysAllow` |
| `PrometheusRule` | `prometheusRule.enabled` | error rate, p95, restarts, circuit breaker ejections, autoscaler at max, rollout degraded |
| `NetworkPolicy` | `networkPolicy.enabled` | ingress: same ns, kong, istio-internal, istio-system, monitoring (+ allowed namespaces); egress: DNS, same ns, data-*, observability, istio-system, istio-egress, integration |
| `ServiceAccount` | `serviceAccount.create` | `automountServiceAccountToken: false` |
| `PersistentVolumeClaim` `<fullname>-<mount>` | `objectStorage.mounts[]` with `mode: csi` + `create: true` | StorageClass `minio-s3` (RWX), `helm.sh/resource-policy: keep` + Argo CD `Prune=false,Delete=false` (deleting it deletes the data) |
| test `Pod` | `helm test` | calls `/health/ready` through the mesh, then stops its sidecar |

## Pod anatomy

```
Pod orders-v1-7c9d8f6b5-x2k4q
├─ init: istio-proxy (native sidecar, injected by Istio, starts first)
├─ init: otel-agent            copies the OTel agent (java: javaagent.jar, dotnet: CLR profiler) into an emptyDir
├─ init: wait-for-postgres     ┐ "startup containers": busybox `nc -z` loop with timeout (startup.timeoutSeconds)
├─ init: wait-for-redis        │ one per enabled dependency
├─ init: wait-for-kafka        │
├─ init: wait-for-minio        ┘ objectStorage.enabled (TCP check of objectStorage.endpoint)
├─ init: s3-sync-<mount>       objectStorage sync mounts: initial pull of bucket/prefix into the mount volume
├─ init: s3-resync-<mount>     native sidecar (restartPolicy: Always) re-syncing every `interval` seconds
├─ init: migrations            optional, same image, same env/secrets, same volumes
├─ init: <initContainers>      user supplied
├─ container: <service.name>   :8080, startup → liveness → readiness probes, preStop sleep 5s, grace 30s
└─ containers: <sidecars>      user supplied
```

Security: `runAsNonRoot`, UID/GID 10001, `readOnlyRootFilesystem`, all capabilities dropped,
`seccompProfile: RuntimeDefault`, no service-account token; `/tmp` is an emptyDir. The preStop hook uses
the native `sleep` action (Kubernetes ≥ 1.30), so it works on distroless and chiseled images that have no
shell. Set `lifecycle.preStopMode: exec` on older clusters.

Startup containers and the mesh: the platform runs Istio with native sidecars, so `istio-proxy` is already
up when the `wait-for-*` and `migrations` containers run. If native sidecars are off, set
`startup.istioNativeSidecars: false`. Those containers then run as UID 1337, which `istio-init` excludes
from traffic capture.

## Language defaults

| | dotnet | java | python |
|-|--------|------|--------|
| Runtime env | `ASPNETCORE_URLS=http://+:8080`, `ASPNETCORE_FORWARDEDHEADERS_ENABLED`, `DOTNET_gcServer=1`, `DOTNET_GCHeapHardLimitPercent=0x4B` (hex!), `DOTNET_GCDynamicAdaptationMode=1` (DATAS) | `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=75 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.io.tmpdir=/tmp`, `SERVER_PORT` | `PYTHONUNBUFFERED`, `PYTHONDONTWRITEBYTECODE`, `WEB_CONCURRENCY = 2 × cpu-request + 1` (capped), `PROMETHEUS_MULTIPROC_DIR` (own emptyDir) |
| APM agent (`apm.agentInjection`) | on: CLR profiler env (`CORECLR_*`, `DOTNET_STARTUP_HOOKS`, `OTEL_DOTNET_AUTO_*`) | on: `-javaagent:/otel-auto-instrumentation-java/javaagent.jar` | off by default (wheels must match the interpreter); on: `PYTHONPATH` to the copied auto-instrumentation |
| OTel extras | `OTEL_DOTNET_AUTO_TRACES_ADDITIONAL_SOURCES=<Service>.*` | `OTEL_INSTRUMENTATION_*` | `OTEL_PYTHON_LOG_CORRELATION`, `OTEL_PYTHON_EXCLUDED_URLS=health/.*,metrics` |
| Probe defaults for unset fields | startup timeout 2s | startup delay 10s / timeout 3s | startup delay 2s |

Every language gets `APP_NAME, APP_VERSION (image tag), API_VERSION, TENANT_ID, ENVIRONMENT, PORT`,
`OTEL_SERVICE_NAME` (`<fullname>`), `OTEL_EXPORTER_OTLP_ENDPOINT`
(`http://otel-collector.observability.svc.cluster.local:4318`, `http/protobuf`), `OTEL_RESOURCE_ATTRIBUTES`
(service.version, deployment.environment, tenant.id, api.version, k8s.*), parent-based ratio sampling
(`apm.samplingRatio`, 10% by default) and W3C propagation. Logs stay on stdout (Fluent Bit); set
`apm.logsExporter: otlp` if you also want them sent over OTLP.

Dependencies inject `DB_*` (`DB_HOST` = PgBouncer pooler unless `pooler: false`, plus `DB_HOST_RO`, `DB_POOLED`),
`REDIS_*` (+ `REDIS_DB`, `REDIS_KEY_PREFIX`, `REDIS_SENTINELS`), `RABBITMQ_*` (+ `RABBITMQ_VHOST`),
`KAFKA_BOOTSTRAP_SERVERS` (+ `KAFKA_SECURITY_PROTOCOL`, `KAFKA_TOPIC_PREFIX`, `KAFKA_CONSUMER_GROUP`).
Passwords are read with `secretKeyRef` from `<fullname>-secrets` (keys `DB_PASSWORD`, `REDIS_PASSWORD`,
`RABBITMQ_PASSWORD`, which you can change with `passwordKey` / `passwordSecret`). A name listed in `env`
overrides the chart's value.

## Examples

### .NET (shared tier)

```yaml
service: {name: orders, version: v1}
language: dotnet
image: {repository: platform/orders, tag: "1.4.2"}
dependencies:
  postgres: {enabled: true, database: orders}
  redis: {enabled: true, db: 1}
  rabbitmq: {enabled: true, vhost: shared}
startup:
  migrations: {enabled: true, command: ["dotnet", "Orders.Migrations.dll"]}
resources: {requests: {cpu: 500m, memory: 512Mi}, limits: {memory: 1Gi}}
autoscaling:
  hpa: {enabled: true, minReplicas: 6, maxReplicas: 60, cpu: 65, memory: 80}
```

### Java (dedicated tenant)

```yaml
service: {name: payments, version: v2}
language: java
tenant: acme
image: {repository: platform/payments, tag: "2.0.1"}
dependencies:
  postgres: {enabled: true}          # DB_NAME/DB_USER default to acme_payments
  kafka: {enabled: true, tls: true}  # KAFKA_TOPIC_PREFIX=acme.
resources: {requests: {cpu: "1", memory: 1Gi}, limits: {memory: 2Gi}}
tuning: {java: {maxRAMPercentage: 70}}
kong: {host: acme.api.example.com}
```

### Python (gunicorn + uvicorn workers)

```yaml
service: {name: catalog, version: v1}
language: python
image: {repository: platform/catalog, tag: "3.2.0"}
resources: {requests: {cpu: 1500m, memory: 512Mi}, limits: {memory: 1Gi}}   # WEB_CONCURRENCY=4
dependencies:
  redis: {enabled: true, db: 3}
apm:
  agentInjection: {python: true}     # only for CPython/glibc images matching the agent image
```

The ready-to-render files in [`ci/`](ci/) cover each language, KEDA and the Deployment mode.

## Multiple versions side by side

```
gitops/tenants/acme/services/orders-v1.yaml   -> release orders-v1 (service.version: v1, image 1.9.3)
gitops/tenants/acme/services/orders-v2.yaml   -> release orders-v2 (service.version: v2, image 2.1.0)
```

```bash
helm upgrade --install orders-v1 charts/microservice -n tenant-acme \
  --set service.name=orders --set service.version=v1 --set image.tag=1.9.3 --set tenant=acme
helm upgrade --install orders-v2 charts/microservice -n tenant-acme \
  --set service.name=orders --set service.version=v2 --set image.tag=2.1.0 --set tenant=acme
```

The two releases have disjoint names (`orders-v1*` / `orders-v2*`) and selectors (`version` label). Kong
routes `https://acme.api.example.com/orders/v1/*` → `orders-v1` and `/orders/v2/*` → `orders-v2`, stripping
the prefix. With `kong.versionHeaderRoute.enabled` a client can also call `/orders/*` with
`X-API-Version: v2`. Inside the mesh, callers use `http://orders-v1` / `http://orders-v2`. Kiali shows one
app `orders` with revisions `v1` and `v2` (Istio canonical labels). Elastic APM shows `orders-v1` and
`orders-v2` as separate services with `service.version` = image tag.

## Canary flow (Argo Rollouts + Istio + Prometheus)

1. CI bumps `image.tag` in Git and Argo CD syncs the Rollout. Rollouts creates the canary ReplicaSet and
   pins the `<fullname>-canary` Service selector to it (and `<fullname>` to the stable ReplicaSet).
2. Each `setWeight` step rewrites the weights of route `primary` in VirtualService `<fullname>`
   (stable 95 / canary 5, then 75/25, and so on). Kong reaches the service through its own sidecar
   (`service-upstream` + `host-header`), so public traffic is split as well as east-west traffic.
3. From `startingStep` (1) a background AnalysisRun queries Prometheus every `interval`:
   - success rate: `sum(rate(istio_requests_total{reporter="destination",destination_service_name="<fullname>-canary",response_code!~"5.."}))`
     divided by the total must be ≥ `successRate`
   - p95: `histogram_quantile(0.95, …istio_request_duration_milliseconds_bucket…)` must be ≤ `p95LatencyMs`

   If there is no canary traffic yet, the check passes (`passOnNoTraffic`).
4. After `failureLimit` failed measurements the rollout **aborts**: weights go back to 100/0, the canary is
   scaled down after `abortScaleDownDelaySeconds`, and the `…RolloutDegraded` alert fires.
5. When the last step (`setWeight: 100`) completes, the canary becomes stable and the weights return to 100/0.

`kubectl argo rollouts get rollout orders-v1 -n tenant-acme --watch`, `promote`, `abort`, `retry`.

### Argo CD: ignore the weights Rollouts mutates

Argo Rollouts edits the VirtualService at runtime. Without an exclusion, Argo CD self-heal would reset the
weights in the middle of a canary. Add this to every Application or ApplicationSet template that deploys
this chart:

```yaml
spec:
  ignoreDifferences:
    - group: networking.istio.io
      kind: VirtualService
      jqPathExpressions:
        - .spec.http[].route[].weight
    - group: ""                       # Rollouts adds rollouts-pod-template-hash to both selectors
      kind: Service
      jqPathExpressions:
        - .spec.selector."rollouts-pod-template-hash"
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

HPA and KEDA own `spec.replicas`, so the chart leaves it out when autoscaling is on and no ignore rule is
needed for it.

## Timeouts, retries and circuit breaking

| Layer | Setting | Default | Meaning |
|-------|---------|---------|---------|
| VirtualService | `istio.timeout` | 10s | Total time budget for a request, **including** retries |
| VirtualService | `istio.retries` | 3 × 3s on `5xx,reset,connect-failure,refused-stream,retriable-4xx,gateway-error` | Retried by the *caller's* sidecar on another endpoint. Keep `attempts × perTryTimeout` within `timeout`, and make only idempotent operations retryable at the application level |
| DestinationRule | `connectionPool` | 2000 TCP conns, 2000 pending, 4000 concurrent h2 requests, 10 concurrent retries | Bulkhead: when full, the request fails fast with 503 (`UO` flag) instead of queueing |
| DestinationRule | `outlierDetection` (`istio.circuitBreaker`) | 5 consecutive 5xx or gateway errors in a 10s scan → eject the pod for 30s × n; at most 50% of the pods | Circuit breaker per endpoint. Ejected pods get no traffic until the ejection time expires |
| DestinationRule | `loadBalancer` | `LEAST_REQUEST` | Better tail latency than round robin with heterogeneous pods |
| DestinationRule | `tls` | `ISTIO_MUTUAL` | mTLS (the tenant chart enforces `PeerAuthentication` STRICT) |

Both DestinationRules (`<fullname>` and `<fullname>-canary`) carry the same policy, so the canary is
protected the same way. The pod's proxy exports `outlier_detection`, `upstream_rq_retry` and overflow
stats (`istio.proxy.statsInclusionRegexps`), which feed the `…CircuitBreakerOpen` alert and Grafana.
Application-level resilience (Polly / Resilience4j / tenacity) stays in charge of calls to non-HTTP
dependencies.

## KEDA

When `autoscaling.keda.enabled: true`, the chart renders a ScaledObject that targets the Rollout or the
Deployment, and no HPA (KEDA creates `keda-hpa-<fullname>`). The HPA `behavior` is reused. A CPU trigger
is added unless `autoscaling.keda.cpu: 0`. Triggers go through `tpl`.

RabbitMQ queue depth (connection string from Vault key `RABBITMQ_URI` in `<fullname>-secrets`):

```yaml
autoscaling:
  keda:
    enabled: true
    minReplicas: 2
    maxReplicas: 40
    triggerAuthentication:
      enabled: true
      secretTargetRef: [{parameter: host, key: RABBITMQ_URI}]
    triggers:
      - type: rabbitmq
        metadata: {protocol: amqp, queueName: '{{ .Values.tenant }}.notifications', mode: QueueLength, value: "100"}
        authenticationRef: {name: '{{ include "microservice.fullname" . }}-keda'}
```

Kafka consumer lag (the consumer group matches `KAFKA_CONSUMER_GROUP`):

```yaml
    triggers:
      - type: kafka
        metadata:
          bootstrapServers: kafka-kafka-bootstrap.data-kafka.svc.cluster.local:9092
          consumerGroup: '{{ .Values.tenant }}.{{ include "microservice.fullname" . }}'
          topic: '{{ .Values.tenant }}.orders-events'
          lagThreshold: "500"
```

Prometheus (RPS per pod through Istio):

```yaml
    triggers:
      - type: prometheus
        metadata:
          serverAddress: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
          query: sum(rate(istio_requests_total{reporter="destination",destination_service_name="{{ include "microservice.fullname" . }}"}[1m]))
          threshold: "800"
```

## Kong exposure

* Route: `https://<kong.host><kong.path or /<service>/<version>>`, `strip-path`, https only (HTTP gets a
  308 redirect), `preserve-host: false`.
* Plugins (namespaced KongPlugins named `<fullname>-*`): `correlation-id` (`X-Correlation-ID`), `jwt`
  (when `auth: jwt`), `rate-limiting` (`policy: redis` on `redis.data-redis`, `limit_by` consumer, or ip
  when `auth: none`, or a header), `request-transformer` that sets `X-Tenant-ID` for dedicated tenants
  (it removes any value the client sent), `response-transformer` that strips `Server`/`X-Powered-By`,
  `prometheus`, `opentelemetry`, plus names listed in `kong.plugins` (e.g. a KongClusterPlugin `cors-default`).
* Istio integration: the stable Service is annotated with `ingress.kubernetes.io/service-upstream: "true"`
  and `konghq.com/host-header: <fullname>.<ns>.svc.cluster.local`. Kong therefore calls the ClusterIP with
  the service host, and the Istio sidecar in the Kong pod applies the VirtualService and DestinationRule
  (canary weights, retries, circuit breaking, mTLS).
* TLS: `cert-manager.io/cluster-issuer: letsencrypt-prod` issues `<fullname>-tls`. Many releases share
  `api.example.com`, so point `kong.tls.secretName` at a shared wildcard certificate and set
  `kong.tls.certManager: false`. This avoids one ACME order per release and Let's Encrypt's duplicate
  certificate limit.
* Rate-limit Redis password: set `kong.rateLimit.redis.passwordSecret` (needs KIC ≥ 3.1 `configPatches`).

## Ephemeral storage

Pod-lifetime storage, gone when the pod is deleted (see [docs/storage.md](../../docs/storage.md) for when to use
block, file or object storage instead).

| Values | Renders | Counts against | Notes |
|--------|---------|----------------|-------|
| `ephemeral.tmp` `{medium: "", sizeLimit: 512Mi}` | `/tmp` emptyDir (always present: read-only root filesystem) | node disk → ephemeral-storage | `medium: Memory` = tmpfs: faster, counts against the container **memory** limit |
| `ephemeral.volumes[]` `type: emptyDir` | emptyDir (`sizeLimit`, `medium`) | ephemeral-storage | node root disk (`/var/snap/microk8s/common/var/lib/kubelet`) |
| `type: memory` | emptyDir `medium: Memory` (`sizeLimit` required) | memory | e.g. `/dev/shm` for Chromium/PyTorch |
| `type: generic` | generic ephemeral volume (`ephemeral.volumeClaimTemplate`), PVC `<pod>-<name>` | PVC count + `requests.storage` quota | `storageClass` default `local-nvme` (dedicated NVMe, WaitForFirstConsumer); large caches, spill files |
| `type: csi` | CSI inline ephemeral volume (`csi:` passthrough) | driver-specific | only for drivers with `volumeLifecycleModes: [Ephemeral]` (e.g. secrets-store). **Not** csi-s3 (Persistent only) |
| `ephemeral.resources` | `requests/limits.ephemeral-storage` merged under `resources` of the app and migrations containers (default 1Gi / 4Gi; an explicit `resources.*.ephemeral-storage` wins) | tenant quota `requests/limits.ephemeral-storage` | the request is used by the scheduler |

Eviction: the kubelet evicts the **pod** when a container's writable layer + logs + disk-backed emptyDirs exceed
the sum of its `ephemeral-storage` limits, or when one emptyDir exceeds its `sizeLimit` (checked every ~10 s, so
short spikes can pass). Evicted pods are replaced by the ReplicaSet; the event reason is `Evicted` with
"ephemeral local storage usage exceeds the total limit". Memory-backed volumes are OOM-killed instead. Under
node disk pressure pods using more than their request are evicted first. Generic ephemeral volumes are never
counted in ephemeral-storage (they are PVCs); with `local-nvme` their size is not enforced (local-path), so
keep an application-side cap.

```yaml
ephemeral:
  tmp: {medium: Memory, sizeLimit: 256Mi}
  volumes:
    - {name: cache, mountPath: /var/cache/app, type: generic, size: 5Gi}          # local-nvme
    - {name: scratch, mountPath: /scratch, type: emptyDir, sizeLimit: 2Gi}
    - {name: shm, mountPath: /dev/shm, type: memory, sizeLimit: 256Mi}
    - name: certs
      mountPath: /mnt/secrets
      readOnly: true
      type: csi
      csi: {driver: secrets-store.csi.k8s.io, readOnly: true, volumeAttributes: {secretProviderClass: app}}
  resources:
    requests: {ephemeral-storage: 2Gi}
    limits: {ephemeral-storage: 8Gi}
```

## Object storage (MinIO)

Tenant buckets, credentials and static bucket volumes are provisioned by `charts/tenant`
(`data.objectStorage`); this chart consumes them. Three ways to use MinIO:

| | 1. SDK (env) | 2. CSI mount (`mode: csi`) | 3. Sync mount (`mode: sync`) |
|-|--------------|-----------------------------|------------------------------|
| How | app uses an S3 SDK with `S3_*` env | bucket/prefix mounted as a directory by csi-s3 (GeeseFS FUSE in the CSI node plugin) | init container mirrors bucket/prefix into a local volume; optional sidecar re-syncs |
| Semantics | full S3 (versioning, presigned URLs, multipart) | POSIX-ish, eventual consistency, no locks/atomic rename, RWX across pods | local files (fast reads), stale up to `interval`, writes are local until pushed |
| Privileges | none | none in the pod (FUSE runs in the privileged node plugin) → PSA `restricted` OK | none: non-root, read-only root fs, no FUSE |
| Best for | new code, uploads/downloads, large objects | legacy code expecting files, shared read-mostly assets | templates, models, static assets read at start; small outputs pushed back |
| Not for | – | databases, heavy small-file writes, anything needing fsync durability | large or fast-changing data sets, multi-writer data |

Enabling `objectStorage` always injects `S3_ENDPOINT` (`https://minio.minio.svc.cluster.local`), `S3_REGION`
(`us-east-1`), `S3_BUCKET` (`<tenant or shared>-files`), `S3_FORCE_PATH_STYLE=true`, `S3_ACCESS_KEY` /
`S3_SECRET_KEY` (Secret `tenant-s3-credentials`, key names configurable under `objectStorage.credentials`),
`S3_CA_FILE` (internal CA from Secret `internal-ca-bundle`, mounted at `/etc/minio-ca`), optional `AWS_*` aliases
(`awsEnvAliases: true`, incl. `AWS_ENDPOINT_URL_S3` and `AWS_CA_BUNDLE`), a `wait-for-minio` startup container and a
NetworkPolicy egress rule to namespace `minio` on ports 443 and 9000 (NetworkPolicies match the MinIO **pod** port).
Pooled releases in `shared-services` use the pool identity `shared` (buckets `shared-*`).

```yaml
objectStorage:
  enabled: true
  mounts:
    # 2a. static bucket mount created by charts/tenant (data.objectStorage.volumes[name=product-images])
    - {name: product-images, mode: csi, mountPath: /data/images, readOnly: true}
    # 2b. chart-created dynamic claim on StorageClass minio-s3 (prefix platform-pvc/<pv>/, platform credentials)
    - {name: uploads, mode: csi, create: true, size: 20Gi, mountPath: /data/uploads}
    # 3a. read-only sync: initial pull + native sidecar pulling every 5 min, deletions mirrored
    - {name: templates, mode: sync, mountPath: /app/templates, readOnly: true, prefix: templates/, interval: 300, remove: true}
    # 3b. push-back: local writes uploaded every 60 s and once more on shutdown (SIGTERM)
    - {name: reports, mode: sync, direction: push, mountPath: /data/reports, prefix: reports/, interval: 60,
       volume: {type: generic, size: 10Gi}}
```

Sync mounts: `tool: mc` (default, `harbor.ops.example.local/platform/mc`) or `rclone`; credentials come from the Secret
as env (`mc alias set` at runtime, never in args), the CA is copied into mc's `certs/CAs`; containers run as UID 10001
with a read-only root filesystem and a small `/tmp/s3sync` emptyDir. `sidecar: native` (default) is an init
container with `restartPolicy: Always` (starts before the app, stops after it; Kubernetes ≥ 1.29); `plain` adds a
regular container. Sidecars write a heartbeat checked by liveness/readiness probes (Kyverno requires probes).

Warnings:
- `direction: bidirectional` = push then pull every interval, **no conflict resolution** (last writer wins, deletions
  are not propagated, concurrent replicas overwrite each other). Prefer one writer per prefix, or the SDK.
- `remove: true` deletes files on the target that are missing on the source (`mc mirror --remove` / `rclone sync`).
- `direction: pull` + `readOnly: false` lets the app modify local copies that the next pull overwrites.
- Each replica keeps its own copy (memory/disk per replica); size `volume` accordingly.
- csi-s3 ignores `readOnly` itself; the chart mounts read-only in the container, and `charts/tenant` adds `-o ro` for
  read-only static volumes. Grant least privilege on the MinIO side for true read-only access.
- Dynamic `create: true` claims live in the platform bucket `platform-pvc` with the csi-s3 platform identity, not in
  the tenant's buckets (docs/storage.md); use tenant static volumes for tenant-owned data.

## Monitoring

`ServiceMonitor` scrapes `http://<pod>:8080/metrics` through the headless `<fullname>-metrics` Service.
When namespaces enforce STRICT mTLS and Prometheus is outside the mesh, set `serviceMonitor.istioMtls: true`.
Prometheus must then mount Istio workload certificates at `/etc/prom-certs` (the standard Istio
"Prometheus with mTLS" setup). The AuthorizationPolicy allows `GET <serviceMonitor.path>` from the
`monitoring` namespace.

## Validate

```bash
helm lint charts/microservice --strict
for f in charts/microservice/ci/*.yaml; do helm template t charts/microservice -f "$f" >/dev/null || exit 1; done
# templates/_storage.tpl is shared with charts/frontend - keep both copies identical:
diff charts/microservice/templates/_storage.tpl charts/frontend/templates/_storage.tpl
```
