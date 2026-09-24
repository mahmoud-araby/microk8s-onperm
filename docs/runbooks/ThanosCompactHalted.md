# ThanosCompactHalted

## Severity

critical (`for: 5m`), label `namespace: monitoring` — `gitops/platform/observability/alerts/manifests/observability-rules.yaml`.

## Meaning

```promql
max(thanos_compact_halted) == 1
```

The Thanos compactor (StatefulSet `thanos-compactor`, **singleton**, `monitoring`) hit a critical error and
halted. It keeps running (so `/-/healthy` is OK) but performs no more compaction, downsampling or retention on
bucket `thanos-metrics` (prefix `microk8s-prod`, MinIO `minio.storage.example.local:9000`, config in Secret
`thanos-objstore`). Most common reason: overlapping blocks (two blocks with the same external labels and
overlapping time ranges) or a corrupted / partially uploaded block.

Configured with: `--retention.resolution-raw=30d`, `--retention.resolution-5m=180d`,
`--retention.resolution-1h=2y`, `--deduplication.replica-label=prometheus_replica` (penalty dedup of the
Prometheus HA pair), `--delete-delay=48h`, scratch PVC `data` 300Gi (`longhorn-db`).

## Impact

No immediate query impact, but: object storage grows without bound (no retention), no downsampled data for
new periods (long-range Grafana queries on the *Thanos* datasource get slow / expensive for the Store Gateway),
and the number of small blocks keeps growing.

## Diagnosis

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=thanos-compactor
kubectl -n monitoring logs statefulset/thanos-compactor --since=24h | grep -iE 'halt|critical|overlap|error' | tail -20
```

The log line before `critical error detected; halting` names the offending block ULIDs.

Inspect the bucket from the compactor pod (same objstore config):

```bash
OBJ=--objstore.config-file=/etc/thanos/objstore/objstore.yml
kubectl -n monitoring exec thanos-compactor-0 -- thanos tools bucket verify $OBJ --issues=overlapped_blocks
kubectl -n monitoring exec thanos-compactor-0 -- thanos tools bucket inspect $OBJ --output=tsv | head -50
```

```promql
thanos_compact_halted
thanos_compact_group_compactions_failures_total
thanos_objstore_bucket_operation_failures_total{job=~".*thanos-compactor.*"}
```

Check what produced the overlap: a Prometheus replica with wrong/missing external labels (`cluster`,
`prometheus_replica`), a second compactor or a second cluster writing to the same prefix, a manual upload.

## Mitigation

1. Transient object-storage error (MinIO unavailable, credentials rotated): fix MinIO / the
   `thanos-objstore` ExternalSecret (Vault `secret/platform/thanos`), then restart:
   `kubectl -n monitoring delete pod thanos-compactor-0` (the halt flag resets on restart).
2. Overlapping blocks from the HA pair are expected and handled by vertical compaction; overlaps from a
   foreign source are not. Exclude the bad block rather than deleting it:
   `thanos tools bucket mark $OBJ --id=<ULID> --marker=no-compact-mark.json --details="overlap, INC-xxx"`,
   then restart the compactor.
3. Corrupted block (e.g. missing `meta.json` / chunks): mark it for deletion
   (`--marker=deletion-mark.json`); it is removed after `--delete-delay=48h`. Its data is lost for long-term
   queries — confirm the time range is still in Prometheus' local 15-day retention if needed.
4. Scratch disk full (compaction fails with "no space left"): expand PVC `data-thanos-compactor-0`
   ([PlatformPVCFillingUp](PlatformPVCFillingUp.md)).
5. Never run two compactors on the same bucket prefix.

## Escalation

On-call (critical) during business hours is sufficient unless the bucket is close to full; observability
owners; storage team for MinIO capacity.

## Related

- [ThanosSidecarUploadFailing](ThanosSidecarUploadFailing.md)
- `gitops/platform/observability/thanos/manifests/thanos-compactor.yaml`
