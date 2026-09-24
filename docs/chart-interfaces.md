# Chart values interfaces (binding contract between charts/, gitops/apps, gitops/tenants, services/)

## charts/microservice  (release/fullname = "<service.name>-<service.version>", e.g. orders-v1)

```yaml
service:
  name: orders            # logical service name
  version: v1             # major API version; multiple versions run side by side
  port: 80                # Service port (named http) -> containerPort 8080
  containerPort: 8080
language: dotnet          # dotnet | java | python  (drives default probes, JVM/.NET/python env tuning, APM agent)
tenant: ""                # tenant id; "" = shared/pooled
environment: production
image:
  registry: harbor.ops.example.local
  repository: platform/orders
  tag: "1.0.0"
  pullPolicy: IfNotPresent
imagePullSecrets: [{name: harbor-pull}]
replicaCount: 3
config: {}                # map -> ConfigMap "<fullname>-config", loaded via envFrom
env: []                   # extra env var entries
externalSecret:
  enabled: true
  refreshInterval: 1h
  vaultPath: ""           # default tenants/<tenant or shared>/<service>; all keys are loaded into Secret "<fullname>-secrets" (envFrom)
dependencies:             # each enabled dependency injects the standard env vars from docs/conventions.md
  postgres: {enabled: false, database: "", user: "", pooler: true}
  redis:    {enabled: false, db: 0, keyPrefix: ""}
  rabbitmq: {enabled: false, vhost: "/"}
  kafka:    {enabled: false}
startup:
  waitForDependencies: true   # init containers ("startup containers") waiting for each enabled dependency TCP endpoint
  migrations: {enabled: false, command: []}   # init container running migrations with the app image
initContainers: []        # extra init containers
sidecars: []              # extra sidecar containers (e.g. log shipper, cloud-sql-proxy-like adapters)
extraVolumes: []
extraVolumeMounts: []
resources: {requests: {cpu: 250m, memory: 256Mi}, limits: {memory: 512Mi}}
probes:                   # defaults: /health/startup, /health/live, /health/ready
  startup:   {path: /health/startup, failureThreshold: 30, periodSeconds: 5}
  liveness:  {path: /health/live,   periodSeconds: 10, timeoutSeconds: 2, failureThreshold: 3}
  readiness: {path: /health/ready,  periodSeconds: 5,  timeoutSeconds: 2, failureThreshold: 3}
rollout:                  # Argo Rollouts canary (if false -> plain Deployment with RollingUpdate)
  enabled: true
  canary:
    steps: [{setWeight: 5}, {pause: {duration: 2m}}, {setWeight: 25}, {pause: {duration: 5m}}, {setWeight: 50}, {pause: {duration: 5m}}, {setWeight: 100}]
    analysis: {enabled: true, successRate: 0.99, p95LatencyMs: 500, interval: 1m, failureLimit: 2}
istio:
  enabled: true
  timeout: 10s
  retries: {attempts: 3, perTryTimeout: 3s, retryOn: "5xx,reset,connect-failure,refused-stream,retriable-4xx,gateway-error"}
  circuitBreaker: {consecutive5xxErrors: 5, consecutiveGatewayErrors: 5, interval: 10s, baseEjectionTime: 30s, maxEjectionPercent: 50}
  connectionPool: {tcp: {maxConnections: 2000, connectTimeout: 2s}, http: {http1MaxPendingRequests: 2000, http2MaxRequests: 4000, maxRequestsPerConnection: 0, maxRetries: 10}}
  loadBalancer: LEAST_REQUEST
  internalGateway: {enabled: false, host: ""}   # expose via istio-internal/internal-gateway
  authorizationPolicy: {enabled: true, allowedNamespaces: [kong, istio-internal, integration]}
kong:
  enabled: true
  host: api.example.com   # tenant dedicated: <tenant>.api.example.com
  path: ""                # default /<service>/<version>
  stripPath: true
  rateLimit: {enabled: true, minute: 1200, policy: redis}
  plugins: []             # extra KongPlugin/KongClusterPlugin names
  auth: jwt               # jwt | none
autoscaling:
  hpa: {enabled: true, minReplicas: 3, maxReplicas: 50, cpu: 70, memory: 80}
  keda: {enabled: false, minReplicas: 3, maxReplicas: 100, triggers: []}   # if enabled replaces HPA (ScaledObject targets Rollout/Deployment)
pdb: {enabled: true, minAvailable: "50%"}
topologySpread: {enabled: true}
serviceMonitor: {enabled: true, interval: 15s, path: /metrics}
prometheusRule: {enabled: true}
networkPolicy: {enabled: true}
serviceAccount: {create: true, annotations: {}}
apm: {enabled: true}      # OTEL_* env; java -> javaagent via init container copy; dotnet -> auto-instrumentation env
podAnnotations: {}
podLabels: {}
nodeSelector: {workload-tier: apps}
tolerations: []
affinity: {}
```

## charts/frontend  (fullname = "<name>" or "<name>-<tenant>")

```yaml
name: web
tenant: ""
image: {registry: harbor.ops.example.local, repository: platform/web, tag: "1.0.0"}
replicaCount: 3
runtimeConfig:           # rendered to /usr/share/nginx/html/config.js as window.__CONFIG__ (no rebuild per tenant)
  apiBaseUrl: https://api.example.com
  authUrl: https://keycloak.example.com/realms/<tenant>
  tenantId: ""
hosts: [app.example.com]
kong: {enabled: true, rateLimit: {minute: 6000}}
tls: {enabled: true, issuer: letsencrypt-prod}
cache: {htmlMaxAge: 0, assetsMaxAge: 31536000}
securityHeaders: {csp: "default-src 'self'; ..."}
rollout: {enabled: true}   # canary for frontend too
autoscaling / pdb / serviceMonitor(nginx exporter sidecar) / networkPolicy / resources / nodeSelector (same shape as microservice)
```

## charts/tenant  (one release per tenant, namespace tenant-<name>)

```yaml
tenant:
  name: acme
  displayName: ACME Corp
  tier: dedicated          # dedicated (own namespace + own service releases) | shared (uses shared-services)
  environment: production
quota: {cpu: "40", memory: 80Gi, pods: "300", pvcs: "20", storage: 500Gi, loadBalancers: "0"}
limitRange: {defaultCpu: 500m, defaultMemory: 512Mi, defaultRequestCpu: 100m, defaultRequestMemory: 128Mi}
rbac: {adminGroups: [acme-admins], developerGroups: [acme-devs], viewerGroups: [acme-viewers]}   # OIDC groups from Keycloak
istio: {injection: true, mtls: STRICT}
networkPolicy: {enabled: true}      # default deny + allow from kong, istio-internal, monitoring, same namespace; egress to data-*, observability, kube-dns, istio-system
data:
  postgres: {enabled: true, databases: [orders, catalog]}   # CNPG Database CRs in data-postgres + ExternalSecret-backed roles
  redis: {db: 1, keyPrefix: "acme:"}
  rabbitmq: {enabled: true, vhost: acme}                    # messaging-topology-operator Vhost/User/Permission
  kafka: {enabled: true, topics: [{name: orders-events, partitions: 12, replicas: 3}]}   # KafkaTopic/KafkaUser in data-kafka, prefixed "<tenant>."
externalSecrets: {enabled: true}    # SecretStore scoped to secret/tenants/<tenant>
keycloak: {realm: acme}
```
