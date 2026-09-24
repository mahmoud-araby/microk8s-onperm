# frontend chart

Hosts a single-page application (React/Angular/Vue build output) on **nginx-unprivileged**. One image
serves every tenant and environment: the per-tenant settings are injected at runtime through `config.js`,
so the image is never rebuilt per tenant.

Resource base name (fullname): `<name>` for the shared frontend (`web` → `app.example.com`), or
`<name>-<tenant>` for a tenant frontend (`web-acme` → `acme.app.example.com`). The values interface is the
contract in [`docs/chart-interfaces.md`](../../docs/chart-interfaces.md). Keys marked `(extra)` in
`values.yaml` are chart additions.

## What gets rendered

| Resource | Notes |
|----------|-------|
| `ConfigMap <fullname>-nginx` | `nginx.conf` + `security-headers.conf` (checksum on the pod template) |
| `ConfigMap <fullname>-runtime-config` | `config.js` → `window.__CONFIG__ = Object.freeze({...})`, mounted at `/usr/share/nginx/html/config.js` |
| `Rollout` (canary) or `Deployment` | same pod model as `charts/microservice`: non-root UID 10001, read-only root filesystem, all capabilities dropped, seccomp RuntimeDefault, `/tmp` emptyDir, probes on `/healthz`, preStop sleep, anti-affinity, zone and host spread |
| sidecar `nginx-exporter` + headless `<fullname>-metrics` Service + `ServiceMonitor` | nginx-prometheus-exporter reads `stub_status` on `127.0.0.1:8081` and serves `:9113/metrics` |
| `Service <fullname>` (+ `-canary`, `-stable-direct`) | port 80 `http` → 8080; Kong `service-upstream` + `host-header` annotations |
| `VirtualService` / `DestinationRule`s / `AuthorizationPolicy` | route `primary` split by Argo Rollouts; mTLS, outlier detection |
| `AnalysisTemplate` | canary success rate and p95 from Istio metrics |
| `Ingress` (class `kong`) + `KongPlugin`s | all `hosts`, TLS through cert-manager (`tls.issuer`), rate limiting (`limit_by: ip`, Redis), correlation id, prometheus |
| `HorizontalPodAutoscaler` or KEDA `ScaledObject`, `PodDisruptionBudget`, `NetworkPolicy`, `PrometheusRule` | same shape as the microservice chart |

## nginx behaviour

| Path | Cache-Control | Notes |
|------|---------------|-------|
| `/index.html`, SPA routes (fallback to `index.html`) | `no-cache` (`cache.htmlMaxAge: 0`) or `public, max-age=N, must-revalidate` | client-side routing: `try_files $uri $uri/ /index.html` |
| fingerprinted assets (`/assets/`, `/static/`, `*.<hash>.js/css/...`, see `cache.immutablePathRegex`) | `public, max-age=31536000, immutable` | |
| other static files (favicon, robots.txt, manifest) | `public, max-age=3600` (`cache.staticMaxAge`) | |
| `/config.js` | `no-store` | runtime configuration |
| `/healthz` | – | probes |

* Compression: gzip (plus `gzip_static` for pre-compressed `.gz` files). Brotli is available with
  `nginx.brotli: true` if the image ships the `ngx_brotli` modules.
* Security headers on every response: `Content-Security-Policy` (`securityHeaders.csp`, which goes through
  `tpl` and so can use `{{ .Values.runtimeConfig.apiBaseUrl }}`), `Strict-Transport-Security`,
  `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`,
  `Cross-Origin-Opener-Policy`, and `X-Correlation-ID` (echoes Kong's header or uses the nginx request id).
* JSON access logs on stdout (with `correlation_id`, `traceparent` and `tenant_id`) for Fluent Bit.
* Every temp path is on `/tmp`, so the container runs with a read-only root filesystem and any non-root UID.
* `worker_processes` is explicit (`nginx.workerProcesses`). `auto` would start one worker per node CPU
  because no CPU limit is set.

## Runtime configuration

```yaml
runtimeConfig:
  apiBaseUrl: https://acme.api.example.com
  authUrl: 'https://keycloak.example.com/realms/{{ .Values.tenant }}'
  tenantId: ""            # defaults to .Values.tenant
  features: {newDashboard: true}
```

This renders to:

```js
window.__CONFIG__ = Object.freeze({"apiBaseUrl":"https://acme.api.example.com","authUrl":"https://keycloak.example.com/realms/acme","environment":"production","features":{"newDashboard":true},"tenantId":"acme","version":"1.8.0"});
```

Load it before the bundle in `index.html`: `<script src="/config.js"></script>`.

## Canary for a SPA

With `rollout.enabled: true`, Argo Rollouts shifts the weights of route `primary` (10% → 50% → 100% by
default) and checks the canary's 5xx ratio and p95 latency. The HTML is split per request, which creates a
problem: a page served by the new version can request `/assets/app-<newhash>.js` from a pod of the old
version, and the reverse. With `rollout.assetFallback: true` (the default), when nginx is missing a
fingerprinted asset it first fetches it from the canary pods, then from the stable pods through
`<fullname>-stable-direct`. That Service selects `role: stable`, which Rollouts sets through
`stableMetadata`, and has no VirtualService attached. An `X-Asset-Fallback` header stops the request from
fanning out again, and a miss on both sides returns 404. Tested with nginx 1.27 under a read-only root
filesystem.

Argo CD must ignore the weights that Rollouts changes. Add this to the Application or ApplicationSet:

```yaml
ignoreDifferences:
  - group: networking.istio.io
    kind: VirtualService
    jqPathExpressions: [.spec.http[].route[].weight]
syncPolicy:
  syncOptions: [RespectIgnoreDifferences=true]
```

## Examples

Shared frontend:

```yaml
name: web
image: {repository: platform/web, tag: "1.8.0"}
hosts: [app.example.com]
```

Tenant frontend (release `web-acme` in `tenant-acme`):

```yaml
name: web
tenant: acme
hosts: [acme.app.example.com]
runtimeConfig:
  apiBaseUrl: https://acme.api.example.com
  authUrl: 'https://keycloak.example.com/realms/{{ .Values.tenant }}'
kong: {enabled: true, rateLimit: {minute: 3000}}
tls: {enabled: true, issuer: letsencrypt-prod}
```

See [`ci/`](ci/) for complete files (shared, tenant with KEDA and the internal gateway, plain Deployment
without mesh).

## Monitoring

`ServiceMonitor` scrapes the exporter (`nginx_connections_*`, `nginx_http_requests_total`, `nginx_up`).
Request rate, errors and latency come from Istio metrics. Alerts: 5xx ratio, p95, restarts, exporter down.
In namespaces with STRICT mTLS where Prometheus is outside the mesh, set `serviceMonitor.istioMtls: true`
(see the microservice README).

## Validate

```bash
helm lint charts/frontend --strict
for f in charts/frontend/ci/*.yaml; do helm template t charts/frontend -f "$f" >/dev/null || exit 1; done
```
