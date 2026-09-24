# ThanosSidecarUploadFailing

## Severity

warning (`for: 30m`), label `namespace: monitoring` — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.

## Meaning

```promql
sum by (pod) (increase(thanos_shipper_upload_failures_total[30m])) > 0
```

The Thanos sidecar in a Prometheus pod (`prometheus-kube-prometheus-stack-prometheus-0/1`, container
`thanos-sidecar`) has failed to upload 2-hour TSDB blocks to object storage for at least 30 minutes. It uses
Secret `thanos-objstore` (key `objstore.yml`: S3 bucket `thanos-metrics`, prefix `microk8s-prod`, endpoint
`minio.storage.example.local:9000`, credentials from Vault `secret/platform/thanos`).

## Impact

No immediate impact: Prometheus keeps 15 days locally (`retention: 15d`, `retentionSize: 420GB`) and the
other HA replica may still upload. If both replicas fail for longer than local retention, long-term metrics
(Grafana *Thanos* datasource, up to 2 years) will have gaps.

## Diagnosis

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus
kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 -c thanos-sidecar --since=2h \
  | grep -iE 'upload|error|denied|timeout' | tail -20
kubectl -n monitoring get externalsecret thanos-objstore; kubectl -n monitoring get secret thanos-objstore
```

```promql
sum by (pod) (increase(thanos_shipper_uploads_total[6h]))
sum by (pod) (increase(thanos_shipper_upload_failures_total[6h]))
time() - thanos_objstore_bucket_last_successful_upload_time    # per pod, if exposed
prometheus_tsdb_lowest_timestamp_seconds                        # how far back local data reaches
```

Typical errors: `AccessDenied` / `InvalidAccessKeyId` (rotated credentials, ESO not refreshed yet), TLS
errors (MinIO certificate), `connection refused` / timeout (MinIO down, network), `XMinioStorageFull` /
quota, or `bucket does not exist`. Also check whether the compactor is healthy
([ThanosCompactHalted](ThanosCompactHalted.md)) — retention stopping can fill the bucket.

## Mitigation

1. Credentials: update Vault `secret/platform/thanos` (`access-key`, `secret-key`), force the ExternalSecret
   refresh (`kubectl -n monitoring annotate externalsecret thanos-objstore force-sync=$(date +%s) --overwrite`),
   then restart one Prometheus pod at a time (`kubectl -n monitoring delete pod
   prometheus-kube-prometheus-stack-prometheus-0`, wait Ready, then `-1`). The sidecar re-reads the config on
   start.
2. MinIO problem: involve the storage team (capacity, availability, certificate). The sidecar retries and
   uploads the backlog of blocks automatically once storage is back (blocks remain on the Prometheus PVC).
3. If the outage will approach 15 days: temporarily raise `retention` / `retentionSize` in
   `gitops/platform/observability/kube-prometheus-stack/values.yaml` (check the 500Gi PVC has room first).
4. Do not delete local blocks by hand.

## Escalation

`#platform-alerts`, observability owners; storage team for MinIO. On-call if both replicas fail for > 24 h.

## Related

- [ThanosCompactHalted](ThanosCompactHalted.md), [PlatformPVCFillingUp](PlatformPVCFillingUp.md)
- `gitops/platform/observability/thanos/manifests/objstore-externalsecret.yaml`
