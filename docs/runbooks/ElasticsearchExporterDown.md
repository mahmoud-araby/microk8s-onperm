# ElasticsearchExporterDown

## Severity

warning (`for: 10m`) — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.

## Meaning

```promql
absent(up{job="elasticsearch-exporter"} == 1)
```

No successful scrape of the Elasticsearch exporter for 10 minutes. The exporter is the Deployment
`elasticsearch-exporter` in `logging` (`gitops/platform/observability/elastic/manifests/elasticsearch-exporter.yaml`,
image `quay.io/prometheuscommunity/elasticsearch-exporter`), listening on `:9114` (Service/ServiceMonitor
`elasticsearch-exporter`, port `http-metrics`, interval 30 s, scrapeTimeout 25 s). It connects to
`https://elasticsearch-es-http.logging.svc.cluster.local:9200` as file-realm user from Secret
`es-user-exporter` (Vault `secret/platform/elastic`, key `exporter-password`), trusting the CA from
`elasticsearch-es-http-certs-public`.

## Impact

Elasticsearch is not monitored: `ElasticsearchClusterRed/Yellow`, `ElasticsearchDiskWatermark` and
`ElasticsearchHeapHigh` cannot fire. Elasticsearch itself may be perfectly healthy.

Note: `up` stays `1` when the exporter runs but cannot reach Elasticsearch — that case shows as
`elasticsearch_cluster_health_up == 0` instead, not as this alert.

## Diagnosis

```bash
kubectl -n logging get deploy,pods -l app.kubernetes.io/name=elasticsearch-exporter -o wide
kubectl -n logging logs deploy/elasticsearch-exporter --tail=100
kubectl -n logging get endpoints elasticsearch-exporter
kubectl -n logging get servicemonitor elasticsearch-exporter
kubectl -n logging get secret es-user-exporter elasticsearch-es-http-certs-public
kubectl -n logging get externalsecret | grep -i exporter      # Vault sync status
```

Prometheus UI (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`) → Status →
Targets → `serviceMonitor/logging/elasticsearch-exporter/0`: last error (timeout, connection refused, TLS).

```promql
up{job="elasticsearch-exporter"}
elasticsearch_cluster_health_up
scrape_duration_seconds{job="elasticsearch-exporter"}
```

Typical causes: pod not scheduled / CrashLoop (missing Secret, bad password after rotation), scrape timeout
because `--es.all` / `--es.data_stream` queries take > 25 s on a stressed cluster, the ServiceMonitor or
Service selector no longer matching the pod labels (`app.kubernetes.io/name: elasticsearch-exporter`).

## Mitigation

1. Pod down / CrashLoop: fix the Secret (`kubectl -n logging describe externalsecret ...`; force a refresh by
   annotating it with `force-sync=$(date +%s)`), then `kubectl -n logging rollout restart deploy/elasticsearch-exporter`.
2. Auth errors (401) after a password rotation: ECK reloads the file realm from `es-user-exporter`; restart the
   exporter so it re-reads the env vars.
3. Scrape timeouts: Elasticsearch is slow — check [ElasticsearchHeapHigh](ElasticsearchHeapHigh.md); as a
   temporary measure drop expensive collectors (e.g. `--es.all`) in Git.
4. While the exporter is down, check health manually (`_cluster/health`, see
   [ElasticsearchClusterRed](ElasticsearchClusterRed.md)) and via the in-cluster probe `elastic-incluster`
   (`probe_success{instance="https://elasticsearch-es-http.logging.svc.cluster.local:9200/"}`).

## Escalation

`#platform-alerts`, observability owners. Not paging by itself.

## Related

- [ElasticsearchClusterRed](ElasticsearchClusterRed.md), [SyntheticProbeFailed](SyntheticProbeFailed.md) (`SyntheticProbeFailedInternal`)
