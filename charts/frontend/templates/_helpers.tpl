{{/* fullname = <name> or <name>-<tenant> */}}
{{- define "frontend.name" -}}
{{- required "name is required" .Values.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "frontend.fullname" -}}
{{- if .Values.tenant -}}
{{- printf "%s-%s" (include "frontend.name" .) .Values.tenant | lower | trunc 49 | trimSuffix "-" -}}
{{- else -}}
{{- include "frontend.name" . -}}
{{- end -}}
{{- end -}}

{{- define "frontend.canaryName" -}}
{{- printf "%s-canary" (include "frontend.fullname" .) -}}
{{- end -}}

{{/* Service selecting only stable pods (role=stable from Rollout stableMetadata), bypassing the VirtualService. */}}
{{- define "frontend.stableDirectName" -}}
{{- printf "%s-stable-direct" (include "frontend.fullname" .) -}}
{{- end -}}

{{- define "frontend.tenant" -}}
{{- .Values.tenant | default "shared" -}}
{{- end -}}

{{- define "frontend.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "frontend.selectorLabels" -}}
app.kubernetes.io/name: {{ include "frontend.name" . }}
app.kubernetes.io/instance: {{ include "frontend.fullname" . }}
{{- end -}}

{{- define "frontend.labels" -}}
{{ include "frontend.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | toString | replace "+" "_" | trunc 63 | quote }}
app.kubernetes.io/component: frontend
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "frontend.chart" . }}
version: {{ .Values.version | default "v1" | quote }}
platform.example.com/tenant: {{ include "frontend.tenant" . }}
platform.example.com/language: static
{{- end -}}

{{- define "frontend.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "frontend.fullname" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "frontend.image" -}}
{{- $ref := printf "%s:%s" .Values.image.repository (toString .Values.image.tag) -}}
{{- if .Values.image.registry -}}{{- $ref = printf "%s/%s" .Values.image.registry $ref -}}{{- end -}}
{{- if .Values.image.digest -}}{{- $ref = printf "%s@%s" $ref .Values.image.digest -}}{{- end -}}
{{- $ref -}}
{{- end -}}

{{- define "frontend.exporterImage" -}}
{{- $i := .Values.serviceMonitor.exporter.image -}}
{{- if $i.registry -}}{{ printf "%s/%s:%s" $i.registry $i.repository (toString $i.tag) }}{{- else -}}{{ printf "%s:%s" $i.repository (toString $i.tag) }}{{- end -}}
{{- end -}}

{{- define "frontend.workloadKind" -}}
{{- if .Values.rollout.enabled -}}Rollout{{- else -}}Deployment{{- end -}}
{{- end -}}

{{- define "frontend.workloadApiVersion" -}}
{{- if .Values.rollout.enabled -}}argoproj.io/v1alpha1{{- else -}}apps/v1{{- end -}}
{{- end -}}

{{- define "frontend.autoscaled" -}}
{{- if or .Values.autoscaling.keda.enabled .Values.autoscaling.hpa.enabled -}}true{{- end -}}
{{- end -}}

{{/* asset fallback between canary and stable pods is only meaningful with a canary behind Istio */}}
{{- define "frontend.assetFallback" -}}
{{- if and .Values.rollout.enabled .Values.istio.enabled .Values.rollout.assetFallback -}}true{{- end -}}
{{- end -}}

{{- define "frontend.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
privileged: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* runtime config object: tenantId defaults to .Values.tenant, strings templated */}}
{{- define "frontend.runtimeConfig" -}}
{{- $out := dict -}}
{{- range $k, $v := .Values.runtimeConfig -}}
{{- if kindIs "string" $v -}}
{{- $_ := set $out $k (tpl $v $) -}}
{{- else -}}
{{- $_ := set $out $k $v -}}
{{- end -}}
{{- end -}}
{{- if not (get $out "tenantId") -}}{{- $_ := set $out "tenantId" (.Values.tenant | default "") -}}{{- end -}}
{{- if not (hasKey $out "environment") -}}{{- $_ := set $out "environment" .Values.environment -}}{{- end -}}
{{- if not (hasKey $out "version") -}}{{- $_ := set $out "version" (toString .Values.image.tag) -}}{{- end -}}
{{- toJson $out -}}
{{- end -}}

{{- define "frontend.probe" -}}
{{- $p := merge (deepCopy (.probe | default dict)) (dict "path" "/healthz" "periodSeconds" 10 "timeoutSeconds" 2 "failureThreshold" 3 "successThreshold" 1 "initialDelaySeconds" 0) -}}
httpGet:
  path: {{ $p.path }}
  port: http
initialDelaySeconds: {{ $p.initialDelaySeconds }}
periodSeconds: {{ $p.periodSeconds }}
timeoutSeconds: {{ $p.timeoutSeconds }}
failureThreshold: {{ $p.failureThreshold }}
successThreshold: {{ $p.successThreshold }}
{{- end -}}

{{/* Pod template shared by Rollout and Deployment */}}
{{- define "frontend.podTemplate" -}}
{{- $v := .Values -}}
{{- $hashKey := ternary "rollouts-pod-template-hash" "pod-template-hash" (eq $v.rollout.enabled true) -}}
metadata:
  labels:
    {{- include "frontend.labels" . | nindent 4 }}
    service.istio.io/canonical-name: {{ include "frontend.fullname" . }}
    service.istio.io/canonical-revision: {{ $v.version | default "v1" | quote }}
    sidecar.istio.io/inject: {{ $v.istio.enabled | quote }}
    {{- with $v.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  annotations:
    kubectl.kubernetes.io/default-container: nginx
    checksum/nginx: {{ include (print $.Template.BasePath "/configmap-nginx.yaml") . | sha256sum }}
    checksum/runtime-config: {{ include (print $.Template.BasePath "/configmap-runtime.yaml") . | sha256sum }}
    {{- if $v.serviceMonitor.enabled }}
    prometheus.io/scrape: "true"
    prometheus.io/port: {{ $v.serviceMonitor.exporter.port | quote }}
    prometheus.io/path: {{ $v.serviceMonitor.path | quote }}
    {{- end }}
    {{- if $v.istio.enabled }}
    sidecar.istio.io/proxyCPU: {{ $v.istio.proxy.cpu | quote }}
    sidecar.istio.io/proxyMemory: {{ $v.istio.proxy.memory | quote }}
    {{- with $v.istio.proxy.memoryLimit }}
    sidecar.istio.io/proxyMemoryLimit: {{ . | quote }}
    {{- end }}
    proxy.istio.io/config: |
      holdApplicationUntilProxyStarts: true
      terminationDrainDuration: 20s
    {{- end }}
    {{- with $v.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "frontend.serviceAccountName" . }}
  automountServiceAccountToken: false
  enableServiceLinks: false
  terminationGracePeriodSeconds: {{ $v.lifecycle.terminationGracePeriodSeconds }}
  {{- with $v.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  {{- with $v.imagePullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: {{ $v.runAsUser | default 10001 }}
    runAsGroup: {{ $v.runAsUser | default 10001 }}
    fsGroup: {{ $v.runAsUser | default 10001 }}
    seccompProfile:
      type: RuntimeDefault
  {{- with (include "platform-storage.syncInitContainers" . | trim) }}
  initContainers:
    {{- /* object storage sync mounts: initial pull, then native sidecars (restartPolicy: Always) */}}
    {{- . | nindent 4 }}
  {{- end }}
  containers:
    - name: nginx
      image: {{ include "frontend.image" . }}
      imagePullPolicy: {{ $v.image.pullPolicy | default "IfNotPresent" }}
      ports:
        - name: http
          containerPort: {{ $v.nginx.port }}
          protocol: TCP
      startupProbe:
        {{- include "frontend.probe" (dict "probe" $v.probes.startup) | nindent 8 }}
      livenessProbe:
        {{- include "frontend.probe" (dict "probe" $v.probes.liveness) | nindent 8 }}
      readinessProbe:
        {{- include "frontend.probe" (dict "probe" $v.probes.readiness) | nindent 8 }}
      lifecycle:
        preStop:
          {{- if and (semverCompare ">=1.30-0" .Capabilities.KubeVersion.Version) (ne $v.lifecycle.preStopMode "exec") }}
          sleep:
            seconds: {{ int $v.lifecycle.preStopSleepSeconds }}
          {{- else }}
          exec:
            command: ["sh", "-c", "sleep {{ int $v.lifecycle.preStopSleepSeconds }}"]
          {{- end }}
      securityContext:
        {{- include "frontend.containerSecurityContext" . | nindent 8 }}
      resources:
        {{- include "platform-storage.appResources" . | nindent 8 }}
      volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
        - name: nginx-conf
          mountPath: /etc/nginx/snippets
          readOnly: true
        - name: runtime-config
          mountPath: /usr/share/nginx/html/config.js
          subPath: config.js
          readOnly: true
        {{- with (include "platform-storage.volumeMounts" . | trim) }}
        {{- . | nindent 8 }}
        {{- end }}
        {{- with $v.extraVolumeMounts }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    {{- if $v.serviceMonitor.enabled }}
    - name: nginx-exporter
      image: {{ include "frontend.exporterImage" . }}
      imagePullPolicy: IfNotPresent
      args:
        - {{ printf "--nginx.scrape-uri=http://127.0.0.1:%v/stub_status" $v.nginx.statusPort }}
        - {{ printf "--web.listen-address=:%v" $v.serviceMonitor.exporter.port }}
        - --web.telemetry-path={{ $v.serviceMonitor.path }}
      ports:
        - name: metrics
          containerPort: {{ $v.serviceMonitor.exporter.port }}
          protocol: TCP
      livenessProbe:
        tcpSocket:
          port: metrics
        periodSeconds: 20
      securityContext:
        {{- include "frontend.containerSecurityContext" . | nindent 8 }}
      resources:
        {{- toYaml $v.serviceMonitor.exporter.resources | nindent 8 }}
    {{- end }}
    {{- with (include "platform-storage.syncSidecars" . | trim) }}
    {{- . | nindent 4 }}
    {{- end }}
  volumes:
    {{- include "platform-storage.tmpVolume" . | nindent 4 }}
    - name: nginx-conf
      configMap:
        name: {{ include "frontend.fullname" . }}-nginx
    - name: runtime-config
      configMap:
        name: {{ include "frontend.fullname" . }}-runtime-config
    {{- with (include "platform-storage.volumes" . | trim) }}
    {{- . | nindent 4 }}
    {{- end }}
    {{- with $v.extraVolumes }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $v.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $v.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  affinity:
    {{- if $v.affinity }}
    {{- toYaml $v.affinity | nindent 4 }}
    {{- else }}
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                {{- include "frontend.selectorLabels" . | nindent 16 }}
    {{- end }}
  {{- if $v.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: {{ $v.topologySpread.maxSkew | default 1 }}
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: {{ $v.topologySpread.zoneWhenUnsatisfiable | default "ScheduleAnyway" }}
      labelSelector:
        matchLabels:
          {{- include "frontend.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [{{ $hashKey }}]
    - maxSkew: {{ $v.topologySpread.maxSkew | default 1 }}
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: {{ $v.topologySpread.hostnameWhenUnsatisfiable | default "ScheduleAnyway" }}
      labelSelector:
        matchLabels:
          {{- include "frontend.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [{{ $hashKey }}]
  {{- end }}
{{- end -}}
