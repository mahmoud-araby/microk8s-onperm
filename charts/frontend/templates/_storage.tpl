{{/* =====================================================================
     Ephemeral storage + object storage (MinIO) helpers.

     This file is IDENTICAL in charts/microservice and charts/frontend (keep them in sync:
     `diff charts/microservice/templates/_storage.tpl charts/frontend/templates/_storage.tpl`).
     Chart-specific names are resolved through "<Chart.Name>.fullname" / "<Chart.Name>.tenant".

     Values consumed: .Values.ephemeral, .Values.objectStorage, .Values.resources.
     Contract: docs/chart-interfaces.md, docs/storage.md.
     ===================================================================== */}}

{{- define "platform-storage.fullname" -}}
{{- include (printf "%s.fullname" .Chart.Name) . -}}
{{- end -}}

{{- define "platform-storage.tenant" -}}
{{- include (printf "%s.tenant" .Chart.Name) . -}}
{{- end -}}

{{/* Hardened container securityContext (PSA restricted). Arg: uid */}}
{{- define "platform-storage.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: {{ .uid | default 10001 }}
runAsGroup: {{ .uid | default 10001 }}
privileged: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* ---------------------------------------------------------------------
     Ephemeral storage
     --------------------------------------------------------------------- */}}

{{/* App container resources: .Values.resources with ephemeral.resources filled in underneath
     (an explicit resources.requests/limits.ephemeral-storage wins). */}}
{{- define "platform-storage.appResources" -}}
{{- $r := deepCopy (.Values.resources | default dict) -}}
{{- $e := ((.Values.ephemeral | default dict).resources | default dict) -}}
{{- toYaml (mergeOverwrite (deepCopy $e) $r) -}}
{{- end -}}

{{/* The /tmp volume (emptyDir: disk or Memory). Arg: root context; default size from ephemeral.tmp.sizeLimit. */}}
{{- define "platform-storage.tmpVolume" -}}
{{- $t := ((.Values.ephemeral | default dict).tmp | default dict) -}}
- name: tmp
  emptyDir:
    {{- if eq (lower (toString ($t.medium | default ""))) "memory" }}
    medium: Memory
    {{- end }}
    {{- with $t.sizeLimit }}
    sizeLimit: {{ . }}
    {{- end }}
{{- end -}}

{{/* One ephemeral volume spec (without the name). Arg: dict "v" <entry> "defaultStorageClass" <sc> */}}
{{- define "platform-storage.ephemeralVolumeSource" -}}
{{- $v := .v -}}
{{- $type := $v.type | default "emptyDir" -}}
{{- if eq $type "emptyDir" }}
emptyDir:
  {{- with $v.medium }}
  medium: {{ . }}
  {{- end }}
  {{- with $v.sizeLimit }}
  sizeLimit: {{ . }}
  {{- end }}
{{- else if eq $type "memory" }}
emptyDir:
  medium: Memory
  sizeLimit: {{ required (printf "sizeLimit is required for memory volume %q (it counts against the container memory limit)" $v.name) $v.sizeLimit }}
{{- else if eq $type "generic" }}
ephemeral:
  volumeClaimTemplate:
    metadata:
      labels:
        platform.example.com/ephemeral-volume: {{ $v.name | quote }}
    spec:
      accessModes: {{ toJson ($v.accessModes | default (list "ReadWriteOnce")) }}
      storageClassName: {{ $v.storageClass | default .defaultStorageClass | quote }}
      resources:
        requests:
          storage: {{ required (printf "size is required for generic ephemeral volume %q" $v.name) $v.size }}
{{- else if eq $type "csi" }}
{{- $c := required (printf "csi is required for csi volume %q" $v.name) $v.csi }}
csi:
  driver: {{ required (printf "csi.driver is required for csi volume %q" $v.name) $c.driver }}
  {{- if hasKey $c "readOnly" }}
  readOnly: {{ $c.readOnly }}
  {{- end }}
  {{- with $c.fsType }}
  fsType: {{ . }}
  {{- end }}
  {{- with $c.volumeAttributes }}
  volumeAttributes:
    {{- range $k, $val := . }}
    {{ $k }}: {{ toString $val | quote }}
    {{- end }}
  {{- end }}
  {{- with $c.nodePublishSecretRef }}
  nodePublishSecretRef:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- else }}
{{- fail (printf "ephemeral.volumes[%s].type must be emptyDir|memory|generic|csi, got %q" $v.name $type) }}
{{- end }}
{{- end -}}

{{/* ---------------------------------------------------------------------
     Object storage (MinIO)
     --------------------------------------------------------------------- */}}

{{- define "platform-storage.s3Enabled" -}}
{{- if ((.Values.objectStorage | default dict).enabled) -}}true{{- end -}}
{{- end -}}

{{- define "platform-storage.bucket" -}}
{{- .Values.objectStorage.bucket | default (printf "%s-files" (include "platform-storage.tenant" .)) -}}
{{- end -}}

{{- define "platform-storage.credentialsSecret" -}}
{{- .Values.objectStorage.credentials.secretName | default "tenant-s3-credentials" -}}
{{- end -}}

{{/* host and port of the S3 endpoint as YAML {host, port, scheme}. */}}
{{- define "platform-storage.endpoint" -}}
{{- $ep := .Values.objectStorage.endpoint | default "https://minio.minio.svc.cluster.local" -}}
{{- $scheme := "https" -}}
{{- if contains "://" $ep -}}{{- $scheme = (splitList "://" $ep | first) -}}{{- end -}}
{{- $hostport := (splitList "://" $ep | last) | trimSuffix "/" -}}
{{- $hostport = (splitList "/" $hostport | first) -}}
{{- $host := $hostport -}}
{{- $port := ternary "443" "80" (eq $scheme "https") -}}
{{- if contains ":" $hostport -}}
{{- $host = (splitList ":" $hostport | first) -}}
{{- $port = (splitList ":" $hostport | last) -}}
{{- end -}}
host: {{ $host }}
port: {{ $port | quote }}
scheme: {{ $scheme }}
url: {{ $ep | trimSuffix "/" }}
{{- end -}}

{{/* true when a CA bundle is mounted for TLS verification of the endpoint */}}
{{- define "platform-storage.caEnabled" -}}
{{- $ca := .Values.objectStorage.ca | default dict -}}
{{- if and (include "platform-storage.s3Enabled" .) (or $ca.secretName $ca.configMapName) -}}true{{- end -}}
{{- end -}}

{{- define "platform-storage.caFile" -}}
{{- $ca := .Values.objectStorage.ca -}}
{{- printf "%s/%s" ($ca.mountPath | default "/etc/minio-ca" | trimSuffix "/") ($ca.key | default "ca.crt") -}}
{{- end -}}

{{/* Normalised list of objectStorage.mounts (enabled ones only) as YAML {items: [...]} */}}
{{- define "platform-storage.mounts" -}}
{{- $root := . -}}
{{- $o := .Values.objectStorage | default dict -}}
{{- $items := list -}}
{{- if $o.enabled -}}
{{- range $o.mounts | default list -}}
{{- if ne .enabled false -}}
{{- $m := deepCopy . -}}
{{- $name := required "objectStorage.mounts[].name is required" $m.name -}}
{{- $_ := required (printf "objectStorage.mounts[%s].mountPath is required" $name) $m.mountPath -}}
{{- $mode := $m.mode | default "csi" -}}
{{- $_ := set $m "mode" $mode -}}
{{- $_ := set $m "volumeName" (printf "s3-%s" $name | trunc 63 | trimSuffix "-") -}}
{{- if eq $mode "csi" -}}
{{- if $m.create -}}
{{- $_ := set $m "claimName" ($m.claimName | default (printf "%s-%s" (include "platform-storage.fullname" $root) $name)) -}}
{{- else -}}
{{- $_ := set $m "claimName" ($m.claimName | default $name) -}}
{{- end -}}
{{- else if eq $mode "sync" -}}
{{- $dir := $m.direction | default "pull" -}}
{{- if not (has $dir (list "pull" "push" "bidirectional")) -}}
{{- fail (printf "objectStorage.mounts[%s].direction must be pull|push|bidirectional, got %q" $name $dir) -}}
{{- end -}}
{{- if and (ne $dir "pull") $m.readOnly -}}
{{- fail (printf "objectStorage.mounts[%s]: readOnly cannot be combined with direction %s" $name $dir) -}}
{{- end -}}
{{- $_ := set $m "direction" $dir -}}
{{- $_ := set $m "bucket" ($m.bucket | default (include "platform-storage.bucket" $root)) -}}
{{- $_ := set $m "prefix" (($m.prefix | default "") | trimPrefix "/" | trimSuffix "/") -}}
{{- $_ := set $m "interval" (int ($m.interval | default 0)) -}}
{{- if and (ne $dir "pull") (le (int $m.interval) 0) -}}
{{- $_ := set $m "interval" 60 -}}
{{- end -}}
{{- $_ := set $m "tool" ($m.tool | default ($o.sync.tool | default "mc")) -}}
{{- if not (has $m.tool (list "mc" "rclone")) -}}
{{- fail (printf "objectStorage.mounts[%s].tool must be mc|rclone" $name) -}}
{{- end -}}
{{- $_ := set $m "sidecar" ($m.sidecar | default ($o.sync.sidecar | default "native")) -}}
{{- else -}}
{{- fail (printf "objectStorage.mounts[%s].mode must be csi|sync, got %q" $name $mode) -}}
{{- end -}}
{{- $items = append $items $m -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml (dict "items" $items) -}}
{{- end -}}

{{/* S3 env for the application container (list items). Arg: root context. */}}
{{- define "platform-storage.s3Env" -}}
{{- if include "platform-storage.s3Enabled" . -}}
{{- $o := .Values.objectStorage -}}
{{- $c := $o.credentials | default dict -}}
{{- $secret := include "platform-storage.credentialsSecret" . -}}
{{- $ep := include "platform-storage.endpoint" . | fromYaml }}
- name: S3_ENDPOINT
  value: {{ $ep.url | quote }}
- name: S3_REGION
  value: {{ $o.region | default "us-east-1" | quote }}
- name: S3_BUCKET
  value: {{ include "platform-storage.bucket" . | quote }}
- name: S3_FORCE_PATH_STYLE
  value: {{ ne $o.forcePathStyle false | quote }}
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $c.accessKeyKey | default "S3_ACCESS_KEY" }}
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $c.secretKeyKey | default "S3_SECRET_KEY" }}
{{- if include "platform-storage.caEnabled" . }}
- name: S3_CA_FILE
  value: {{ include "platform-storage.caFile" . | quote }}
{{- end }}
{{- if $o.awsEnvAliases }}
- name: AWS_ACCESS_KEY_ID
  value: "$(S3_ACCESS_KEY)"
- name: AWS_SECRET_ACCESS_KEY
  value: "$(S3_SECRET_KEY)"
- name: AWS_REGION
  value: {{ $o.region | default "us-east-1" | quote }}
- name: AWS_DEFAULT_REGION
  value: {{ $o.region | default "us-east-1" | quote }}
- name: AWS_ENDPOINT_URL_S3
  value: {{ $ep.url | quote }}
- name: AWS_S3_FORCE_PATH_STYLE
  value: {{ ne $o.forcePathStyle false | quote }}
{{- if include "platform-storage.caEnabled" . }}
- name: AWS_CA_BUNDLE
  value: {{ include "platform-storage.caFile" . | quote }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/* Pod volumes: ephemeral.volumes + object storage mounts + CA bundle (list items). */}}
{{- define "platform-storage.volumes" -}}
{{- $root := . -}}
{{- $e := .Values.ephemeral | default dict -}}
{{- range $e.volumes | default list }}
- name: {{ required "ephemeral.volumes[].name is required" .name }}
  {{- include "platform-storage.ephemeralVolumeSource" (dict "v" . "defaultStorageClass" ($e.defaultStorageClass | default "local-nvme")) | trim | nindent 2 }}
{{- end }}
{{- if include "platform-storage.s3Enabled" . }}
{{- $o := .Values.objectStorage }}
{{- range (include "platform-storage.mounts" . | fromYaml).items }}
{{- if eq .mode "csi" }}
- name: {{ .volumeName }}
  persistentVolumeClaim:
    claimName: {{ .claimName }}
    {{- if .readOnly }}
    readOnly: true
    {{- end }}
{{- else }}
{{- $vol := .volume | default dict }}
- name: {{ .volumeName }}
  {{- include "platform-storage.ephemeralVolumeSource" (dict "v" (merge (deepCopy $vol) (dict "name" .name "type" "emptyDir" "sizeLimit" "1Gi")) "defaultStorageClass" ($e.defaultStorageClass | default "local-nvme")) | trim | nindent 2 }}
{{- end }}
{{- end }}
{{- if include "platform-storage.caEnabled" . }}
{{- $ca := $o.ca }}
- name: minio-ca
  {{- if $ca.secretName }}
  secret:
    secretName: {{ $ca.secretName }}
    items:
      - key: {{ $ca.key | default "ca.crt" }}
        path: {{ $ca.key | default "ca.crt" }}
  {{- else }}
  configMap:
    name: {{ $ca.configMapName }}
    items:
      - key: {{ $ca.key | default "ca.crt" }}
        path: {{ $ca.key | default "ca.crt" }}
  {{- end }}
{{- end }}
{{- if (include "platform-storage.syncMounts" . | trim) }}
- name: s3-sync-tmp
  emptyDir:
    sizeLimit: 64Mi
{{- end }}
{{- end }}
{{- end -}}

{{/* Volume mounts for the application container (list items). */}}
{{- define "platform-storage.volumeMounts" -}}
{{- range ((.Values.ephemeral | default dict).volumes | default list) }}
- name: {{ .name }}
  mountPath: {{ required (printf "ephemeral.volumes[%s].mountPath is required" .name) .mountPath }}
  {{- with .subPath }}
  subPath: {{ . }}
  {{- end }}
  {{- if .readOnly }}
  readOnly: true
  {{- end }}
{{- end }}
{{- if include "platform-storage.s3Enabled" . }}
{{- range (include "platform-storage.mounts" . | fromYaml).items }}
- name: {{ .volumeName }}
  mountPath: {{ .mountPath }}
  {{- if and (eq .mode "csi") .subPath }}
  subPath: {{ .subPath }}
  {{- end }}
  {{- if .readOnly }}
  readOnly: true
  {{- end }}
{{- end }}
{{- if include "platform-storage.caEnabled" . }}
- name: minio-ca
  mountPath: {{ .Values.objectStorage.ca.mountPath | default "/etc/minio-ca" }}
  readOnly: true
{{- end }}
{{- end }}
{{- end -}}

{{/* Non-empty when at least one sync-mode mount exists. */}}
{{- define "platform-storage.syncMounts" -}}
{{- range (include "platform-storage.mounts" . | fromYaml).items }}{{ if eq .mode "sync" }}{{ .name }} {{ end }}{{ end -}}
{{- end -}}

{{/* Image of the sync containers for a tool (mc | rclone). Arg: dict "root" "tool" */}}
{{- define "platform-storage.syncImage" -}}
{{- $i := index .root.Values.objectStorage.sync.images .tool -}}
{{- if $i.registry -}}{{ printf "%s/%s:%s" $i.registry $i.repository (toString $i.tag) }}{{- else -}}{{ printf "%s:%s" $i.repository (toString $i.tag) }}{{- end -}}
{{- end -}}

{{/* Env of a sync container. Arg: dict "root" "m" */}}
{{- define "platform-storage.syncEnv" -}}
{{- $root := .root -}}
{{- $m := .m -}}
{{- $o := $root.Values.objectStorage -}}
{{- $c := $o.credentials | default dict -}}
{{- $secret := include "platform-storage.credentialsSecret" $root -}}
{{- $ep := include "platform-storage.endpoint" $root | fromYaml -}}
- {name: HOME, value: /tmp/s3sync}
- {name: S3_ENDPOINT, value: {{ $ep.url | quote }}}
- {name: S3_REGION, value: {{ $o.region | default "us-east-1" | quote }}}
- {name: S3_BUCKET, value: {{ $m.bucket | quote }}}
- {name: S3_SRC, value: {{ trimSuffix "/" (printf "%s/%s" $m.bucket $m.prefix) | quote }}}
- {name: SYNC_DIR, value: /data}
- {name: SYNC_INTERVAL, value: {{ $m.interval | quote }}}
- {name: SYNC_TIMEOUT, value: {{ $o.sync.timeoutSeconds | default 300 | quote }}}
- name: S3_ACCESS_KEY
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: {{ $c.accessKeyKey | default "S3_ACCESS_KEY" }}}}
- name: S3_SECRET_KEY
  valueFrom: {secretKeyRef: {name: {{ $secret }}, key: {{ $c.secretKeyKey | default "S3_SECRET_KEY" }}}}
{{- if include "platform-storage.caEnabled" $root }}
- {name: S3_CA_FILE, value: {{ include "platform-storage.caFile" $root | quote }}}
{{- end }}
{{- if eq $m.tool "rclone" }}
- {name: RCLONE_CONFIG, value: /tmp/s3sync/rclone.conf}
- {name: RCLONE_CACHE_DIR, value: /tmp/s3sync/cache}
- {name: RCLONE_CONFIG_MINIO_TYPE, value: s3}
- {name: RCLONE_CONFIG_MINIO_PROVIDER, value: Minio}
- {name: RCLONE_CONFIG_MINIO_ENV_AUTH, value: "false"}
- {name: RCLONE_CONFIG_MINIO_ACCESS_KEY_ID, value: "$(S3_ACCESS_KEY)"}
- {name: RCLONE_CONFIG_MINIO_SECRET_ACCESS_KEY, value: "$(S3_SECRET_KEY)"}
- {name: RCLONE_CONFIG_MINIO_ENDPOINT, value: {{ $ep.url | quote }}}
- {name: RCLONE_CONFIG_MINIO_REGION, value: {{ $o.region | default "us-east-1" | quote }}}
- {name: RCLONE_CONFIG_MINIO_FORCE_PATH_STYLE, value: "true"}
{{- if include "platform-storage.caEnabled" $root }}
- {name: RCLONE_CA_CERT, value: {{ include "platform-storage.caFile" $root | quote }}}
{{- end }}
{{- end }}
{{- end -}}

{{/* Shell script of a sync container. Arg: dict "root" "m" "phase" (init | loop) */}}
{{- define "platform-storage.syncScript" -}}
{{- $m := .m -}}
{{- $extra := join " " ($m.extraArgs | default list) -}}
set -eu
mkdir -p "$HOME"
{{- if eq $m.tool "mc" }}
# mc: alias from env (secret values never appear in args or in the pod spec); CA via <config-dir>/certs/CAs.
MC="mc --config-dir $HOME/.mc --quiet --no-color"
mkdir -p "$HOME/.mc/certs/CAs"
if [ -n "${S3_CA_FILE:-}" ]; then cp "$S3_CA_FILE" "$HOME/.mc/certs/CAs/minio-ca.crt"; fi
end=$(( $(date +%s) + SYNC_TIMEOUT ))
until $MC alias set minio "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" --api S3v4 --path on >/dev/null 2>&1 && $MC ls "minio/$S3_BUCKET" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$end" ]; then echo "timeout: cannot list bucket $S3_BUCKET at $S3_ENDPOINT"; $MC ls "minio/$S3_BUCKET" || true; exit 1; fi
  echo "waiting for s3 $S3_ENDPOINT/$S3_BUCKET"; sleep 3
done
has_src() { [ -n "$($MC ls "minio/$S3_SRC/" 2>/dev/null | head -n 1)" ]; }
pull() { if has_src; then $MC mirror --overwrite {{ if and $m.remove (eq $m.direction "pull") }}--remove {{ end }}{{ $extra }} "minio/$S3_SRC/" "$SYNC_DIR/"; else echo "minio/$S3_SRC/ is empty"; fi; }
push() { $MC mirror --overwrite {{ if and $m.remove (eq $m.direction "push") }}--remove {{ end }}{{ $extra }} "$SYNC_DIR/" "minio/$S3_SRC/"; }
{{- else }}
# rclone: remote "minio:" configured from RCLONE_CONFIG_MINIO_* env.
: > "$RCLONE_CONFIG"
end=$(( $(date +%s) + SYNC_TIMEOUT ))
until rclone lsf --max-depth 1 "minio:$S3_BUCKET" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$end" ]; then echo "timeout: cannot list bucket $S3_BUCKET at $S3_ENDPOINT"; rclone lsf --max-depth 1 "minio:$S3_BUCKET" || true; exit 1; fi
  echo "waiting for s3 $S3_ENDPOINT/$S3_BUCKET"; sleep 3
done
has_src() { [ -n "$(rclone lsf --max-depth 1 "minio:$S3_SRC" 2>/dev/null | head -n 1)" ]; }
pull() { if ! has_src; then echo "minio:$S3_SRC is empty"; return 0; fi; rclone {{ ternary "sync" "copy" (and (eq $m.direction "pull") (eq $m.remove true)) }} {{ $extra }} "minio:$S3_SRC" "$SYNC_DIR"; }
push() { rclone {{ ternary "sync" "copy" (and (eq $m.direction "push") (eq $m.remove true)) }} {{ $extra }} "$SYNC_DIR" "minio:$S3_SRC"; }
{{- end }}
{{- if eq .phase "init" }}
echo "initial pull minio/$S3_SRC -> $SYNC_DIR"
pull
echo "initial pull done"
{{- else }}
{{- if ne $m.direction "pull" }}
# final upload on shutdown (the kubelet stops sidecars after the app container)
trap 'echo "final push"; push; exit 0' TERM INT
{{- end }}
echo "sync loop ({{ $m.direction }}) every ${SYNC_INTERVAL}s"
date +%s > "$HOME/heartbeat"
while true; do
  sleep "$SYNC_INTERVAL" & wait $!
  date +%s > "$HOME/heartbeat"
  {{- if eq $m.direction "pull" }}
  pull || echo "pull failed (will retry)"
  {{- else if eq $m.direction "push" }}
  push || echo "push failed (will retry)"
  {{- else }}
  push || echo "push failed (will retry)"
  pull || echo "pull failed (will retry)"
  {{- end }}
done
{{- end }}
{{- end -}}

{{/* One sync container. Arg: dict "root" "m" "phase" (init | loop) "native" bool */}}
{{- define "platform-storage.syncContainer" -}}
{{- $root := .root -}}
{{- $m := .m -}}
{{- $o := $root.Values.objectStorage -}}
- name: {{ printf "s3-%s-%s" (ternary "sync" "resync" (eq .phase "init")) $m.name | trunc 63 | trimSuffix "-" }}
  image: {{ include "platform-storage.syncImage" (dict "root" $root "tool" $m.tool) }}
  imagePullPolicy: IfNotPresent
  {{- if .native }}
  restartPolicy: Always
  {{- end }}
  command: ["/bin/sh", "-c"]
  args:
    - |
      {{- include "platform-storage.syncScript" (dict "root" $root "m" $m "phase" .phase) | nindent 6 }}
  env:
    {{- include "platform-storage.syncEnv" (dict "root" $root "m" $m) | nindent 4 }}
  securityContext:
    {{- include "platform-storage.securityContext" (dict "uid" ($o.sync.runAsUser | default 10001)) | nindent 4 }}
  resources:
    {{- toYaml ($m.resources | default $o.sync.resources) | nindent 4 }}
  {{- if eq .phase "loop" }}
  {{- /* heartbeat written by every loop iteration; stale after 3 intervals + the command timeout */}}
  {{- $stale := add (mul 3 (int $m.interval)) (int ($o.sync.timeoutSeconds | default 300)) }}
  livenessProbe:
    exec:
      command: ["/bin/sh", "-c", "[ $(( $(date +%s) - $(cat /tmp/s3sync/heartbeat) )) -lt {{ $stale }} ]"]
    initialDelaySeconds: 30
    periodSeconds: 60
    timeoutSeconds: 5
    failureThreshold: 3
  readinessProbe:
    exec:
      command: ["/bin/sh", "-c", "test -f /tmp/s3sync/heartbeat"]
    periodSeconds: 30
    timeoutSeconds: 5
  {{- end }}
  volumeMounts:
    - name: {{ $m.volumeName }}
      mountPath: /data
    - name: s3-sync-tmp
      mountPath: /tmp/s3sync
      subPath: {{ $m.name }}
    {{- if include "platform-storage.caEnabled" $root }}
    - name: minio-ca
      mountPath: {{ $o.ca.mountPath | default "/etc/minio-ca" }}
      readOnly: true
    {{- end }}
{{- end -}}

{{/* Init containers for sync mounts: initial pull (pull / bidirectional) + native sidecars (restartPolicy Always). */}}
{{- define "platform-storage.syncInitContainers" -}}
{{- $root := . -}}
{{- if include "platform-storage.s3Enabled" . }}
{{- range (include "platform-storage.mounts" . | fromYaml).items }}
{{- if eq .mode "sync" }}
{{- if ne .direction "push" }}
{{ include "platform-storage.syncContainer" (dict "root" $root "m" . "phase" "init" "native" false) }}
{{- end }}
{{- if and (gt (int .interval) 0) (eq .sidecar "native") }}
{{ include "platform-storage.syncContainer" (dict "root" $root "m" . "phase" "loop" "native" true) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Plain sidecar containers for sync mounts with sidecar: plain. */}}
{{- define "platform-storage.syncSidecars" -}}
{{- $root := . -}}
{{- if include "platform-storage.s3Enabled" . }}
{{- range (include "platform-storage.mounts" . | fromYaml).items }}
{{- if and (eq .mode "sync") (gt (int .interval) 0) (eq .sidecar "plain") }}
{{ include "platform-storage.syncContainer" (dict "root" $root "m" . "phase" "loop" "native" false) }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/* NetworkPolicy egress rule to MinIO (list item). */}}
{{- define "platform-storage.netpolEgress" -}}
{{- if include "platform-storage.s3Enabled" . }}
{{- $np := .Values.objectStorage.networkPolicy | default dict }}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ $np.namespace | default "minio" }}
  ports:
    {{- range ($np.ports | default (list 443 9000)) }}
    - {protocol: TCP, port: {{ . }}}
    {{- end }}
{{- end }}
{{- end -}}

{{/* PersistentVolumeClaims for csi mounts with create: true (dynamic provisioning, e.g. StorageClass minio-s3). */}}
{{- define "platform-storage.pvcs" -}}
{{- $root := . -}}
{{- if include "platform-storage.s3Enabled" . }}
{{- range (include "platform-storage.mounts" . | fromYaml).items }}
{{- if and (eq .mode "csi") .create }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .claimName }}
  labels:
    {{- include (printf "%s.labels" $root.Chart.Name) $root | nindent 4 }}
  annotations:
    {{- if ne .keep false }}
    # Deleting the claim deletes the dynamically provisioned bucket/prefix (reclaimPolicy of the StorageClass).
    helm.sh/resource-policy: keep
    argocd.argoproj.io/sync-options: Prune=false,Delete=false
    {{- end }}
spec:
  accessModes: {{ toJson (.accessModes | default (list "ReadWriteMany")) }}
  storageClassName: {{ .storageClass | default "minio-s3" | quote }}
  resources:
    requests:
      storage: {{ .size | default "10Gi" }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}
