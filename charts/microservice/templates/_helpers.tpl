{{/* =====================================================================
     Names
     ===================================================================== */}}

{{/* Logical service name (app.kubernetes.io/name). */}}
{{- define "microservice.name" -}}
{{- required "service.name is required" .Values.service.name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/* fullname = <service.name>-<service.version>, e.g. orders-v1.
     Truncated to 55 chars so that "<fullname>-canary" is still a valid Service name (<= 63). */}}
{{- define "microservice.fullname" -}}
{{- $version := required "service.version is required" .Values.service.version -}}
{{- printf "%s-%s" (include "microservice.name" .) $version | lower | trunc 55 | trimSuffix "-" -}}
{{- end -}}

{{- define "microservice.canaryName" -}}
{{- printf "%s-canary" (include "microservice.fullname" .) -}}
{{- end -}}

{{- define "microservice.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Tenant label value: "" -> shared. */}}
{{- define "microservice.tenant" -}}
{{- .Values.tenant | default "shared" -}}
{{- end -}}

{{/* Image tag sanitised for use as a label value. */}}
{{- define "microservice.versionLabel" -}}
{{- .Values.image.tag | toString | replace "+" "_" | replace ":" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "microservice.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "microservice.fullname" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{- define "microservice.image" -}}
{{- $ref := printf "%s:%s" .Values.image.repository (toString .Values.image.tag) -}}
{{- if .Values.image.registry -}}{{- $ref = printf "%s/%s" .Values.image.registry $ref -}}{{- end -}}
{{- if .Values.image.digest -}}{{- $ref = printf "%s@%s" $ref .Values.image.digest -}}{{- end -}}
{{- $ref -}}
{{- end -}}

{{- define "microservice.startupImage" -}}
{{- $i := .Values.startup.image -}}
{{- if $i.registry -}}{{ printf "%s/%s:%s" $i.registry $i.repository (toString $i.tag) }}{{- else -}}{{ printf "%s:%s" $i.repository (toString $i.tag) }}{{- end -}}
{{- end -}}

{{/* Workload kind targeted by HPA / KEDA / PDB. */}}
{{- define "microservice.workloadKind" -}}
{{- if .Values.rollout.enabled -}}Rollout{{- else -}}Deployment{{- end -}}
{{- end -}}

{{- define "microservice.workloadApiVersion" -}}
{{- if .Values.rollout.enabled -}}argoproj.io/v1alpha1{{- else -}}apps/v1{{- end -}}
{{- end -}}

{{/* true when an autoscaler owns spec.replicas */}}
{{- define "microservice.autoscaled" -}}
{{- if or .Values.autoscaling.keda.enabled .Values.autoscaling.hpa.enabled -}}true{{- end -}}
{{- end -}}

{{/* Kong route path: /<service>/<version> by default. */}}
{{- define "microservice.kongPath" -}}
{{- .Values.kong.path | default (printf "/%s/%s" (include "microservice.name" .) .Values.service.version) -}}
{{- end -}}

{{/* Vault path: tenants/<tenant or shared>/<service>. */}}
{{- define "microservice.vaultPath" -}}
{{- .Values.externalSecret.vaultPath | default (printf "tenants/%s/%s" (include "microservice.tenant" .) (include "microservice.name" .)) -}}
{{- end -}}

{{- define "microservice.secretName" -}}
{{- printf "%s-secrets" (include "microservice.fullname" .) -}}
{{- end -}}

{{- define "microservice.configName" -}}
{{- printf "%s-config" (include "microservice.fullname" .) -}}
{{- end -}}

{{/* =====================================================================
     Labels
     ===================================================================== */}}

{{- define "microservice.selectorLabels" -}}
app.kubernetes.io/name: {{ include "microservice.name" . }}
app.kubernetes.io/instance: {{ include "microservice.fullname" . }}
version: {{ .Values.service.version | quote }}
{{- end -}}

{{- define "microservice.labels" -}}
{{ include "microservice.selectorLabels" . }}
app.kubernetes.io/version: {{ include "microservice.versionLabel" . | quote }}
app.kubernetes.io/component: {{ .Values.service.component | default "api" }}
app.kubernetes.io/part-of: {{ .Values.service.partOf | default "platform" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "microservice.chart" . }}
platform.example.com/tenant: {{ include "microservice.tenant" . }}
platform.example.com/language: {{ .Values.language }}
{{- end -}}

{{/* Labels only on pods (Istio canonical service -> Kiali shows "orders" with revisions v1, v2). */}}
{{- define "microservice.podLabels" -}}
{{ include "microservice.labels" . }}
service.istio.io/canonical-name: {{ include "microservice.name" . }}
service.istio.io/canonical-revision: {{ .Values.service.version | quote }}
sidecar.istio.io/inject: {{ .Values.istio.enabled | quote }}
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* =====================================================================
     Language defaults
     Returns a YAML dict for the active language: probe defaults (only
     used for fields not set in .Values.probes), APM agent copy spec and
     runtime notes. Consumed with `include ... | fromYaml`.
     ===================================================================== */}}
{{- define "microservice.languageDefaults" -}}
{{- $lang := .Values.language -}}
{{- if eq $lang "java" }}
probes:
  startup:   {initialDelaySeconds: 10, timeoutSeconds: 3, periodSeconds: 5, failureThreshold: 36}
  liveness:  {initialDelaySeconds: 0, timeoutSeconds: 3, periodSeconds: 10, failureThreshold: 3}
  readiness: {initialDelaySeconds: 0, timeoutSeconds: 3, periodSeconds: 5, failureThreshold: 3}
agent:
  volume: otel-agent-java
  mountPath: /otel-auto-instrumentation-java
  command: ["cp", "/javaagent.jar", "/otel-auto-instrumentation-java/javaagent.jar"]
{{- else if eq $lang "dotnet" }}
probes:
  startup:   {initialDelaySeconds: 0, timeoutSeconds: 2, periodSeconds: 5, failureThreshold: 24}
  liveness:  {initialDelaySeconds: 0, timeoutSeconds: 2, periodSeconds: 10, failureThreshold: 3}
  readiness: {initialDelaySeconds: 0, timeoutSeconds: 2, periodSeconds: 5, failureThreshold: 3}
agent:
  volume: otel-agent-dotnet
  mountPath: /otel-auto-instrumentation-dotnet
  command: ["cp", "-r", "/autoinstrumentation/.", "/otel-auto-instrumentation-dotnet"]
{{- else if eq $lang "python" }}
probes:
  startup:   {initialDelaySeconds: 2, timeoutSeconds: 2, periodSeconds: 5, failureThreshold: 24}
  liveness:  {initialDelaySeconds: 0, timeoutSeconds: 2, periodSeconds: 10, failureThreshold: 3}
  readiness: {initialDelaySeconds: 0, timeoutSeconds: 2, periodSeconds: 5, failureThreshold: 3}
agent:
  volume: otel-agent-python
  mountPath: /otel-auto-instrumentation-python
  command: ["cp", "-r", "/autoinstrumentation/.", "/otel-auto-instrumentation-python"]
{{- else }}
{{- fail (printf "language must be one of dotnet|java|python, got %q" $lang) }}
{{- end }}
{{- end -}}

{{/* true when an OTel agent is copied into the pod for the active language */}}
{{- define "microservice.agentInjected" -}}
{{- if and .Values.apm.enabled (index .Values.apm.agentInjection .Values.language) -}}true{{- end -}}
{{- end -}}

{{/* CPU request in millicores (used for WEB_CONCURRENCY). */}}
{{- define "microservice.cpuMillis" -}}
{{- $cpu := toString (((.Values.resources).requests).cpu | default "250m") -}}
{{- if hasSuffix "m" $cpu -}}
{{- trimSuffix "m" $cpu | int -}}
{{- else -}}
{{- mulf (float64 $cpu) 1000 | int -}}
{{- end -}}
{{- end -}}

{{/* Renders one probe: user values > language defaults > generic defaults. Args: dict "probe" "lang" "path" */}}
{{- define "microservice.probe" -}}
{{- $p := merge (deepCopy (.probe | default dict)) (deepCopy (.lang | default dict)) (dict "path" .path "periodSeconds" 10 "timeoutSeconds" 2 "failureThreshold" 3 "successThreshold" 1 "initialDelaySeconds" 0) -}}
httpGet:
  path: {{ $p.path }}
  port: http
initialDelaySeconds: {{ $p.initialDelaySeconds }}
periodSeconds: {{ $p.periodSeconds }}
timeoutSeconds: {{ $p.timeoutSeconds }}
failureThreshold: {{ $p.failureThreshold }}
successThreshold: {{ $p.successThreshold }}
{{- end -}}

{{/* =====================================================================
     Security contexts
     ===================================================================== */}}
{{- define "microservice.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "microservice.containerSecurityContext" -}}
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

{{/* UID for startup containers: 1337 bypasses Istio capture when native sidecars are off. */}}
{{- define "microservice.startupUid" -}}
{{- if and .Values.istio.enabled (not .Values.startup.istioNativeSidecars) -}}1337{{- else -}}10001{{- end -}}
{{- end -}}

{{/* =====================================================================
     Dependency helpers
     ===================================================================== */}}
{{- define "microservice.pgDatabase" -}}
{{- if .Values.dependencies.postgres.database -}}
{{- .Values.dependencies.postgres.database -}}
{{- else if .Values.tenant -}}
{{- printf "%s_%s" .Values.tenant (include "microservice.name" .) | replace "-" "_" -}}
{{- else -}}
{{- include "microservice.name" . | replace "-" "_" -}}
{{- end -}}
{{- end -}}

{{- define "microservice.dependencyEndpoints" -}}
{{- $e := .Values.endpoints -}}
{{- $d := .Values.dependencies -}}
{{- if $d.postgres.enabled }}
- name: postgres
  host: {{ ternary $e.postgres.pooler $e.postgres.rw (ne $d.postgres.pooler false) }}
  port: {{ $e.postgres.port }}
{{- end }}
{{- if $d.redis.enabled }}
- name: redis
  host: {{ $e.redis.host }}
  port: {{ $e.redis.port }}
{{- end }}
{{- if $d.rabbitmq.enabled }}
- name: rabbitmq
  host: {{ $e.rabbitmq.host }}
  port: {{ $e.rabbitmq.port }}
{{- end }}
{{- if $d.kafka.enabled }}
{{- $bs := ternary $e.kafka.bootstrapTls $e.kafka.bootstrap (eq $d.kafka.tls true) }}
- name: kafka
  host: {{ (splitList ":" $bs) | first }}
  port: {{ (splitList ":" $bs) | last }}
{{- end }}
{{- end -}}

{{/* =====================================================================
     Standard environment (docs/conventions.md). Emitted as a YAML list;
     the pod template drops entries whose name is re-defined in .Values.env.
     Order matters: K8S_* must precede OTEL_RESOURCE_ATTRIBUTES ($(VAR) expansion).
     ===================================================================== */}}
{{- define "microservice.stdEnv" -}}
{{- $v := .Values -}}
{{- $fullname := include "microservice.fullname" . -}}
{{- $name := include "microservice.name" . -}}
{{- $tenant := include "microservice.tenant" . -}}
{{- $secret := include "microservice.secretName" . -}}
{{- $lang := $v.language -}}
{{- $ld := include "microservice.languageDefaults" . | fromYaml -}}
{{- $agent := include "microservice.agentInjected" . -}}
- name: K8S_POD_NAME
  valueFrom: {fieldRef: {fieldPath: metadata.name}}
- name: K8S_NAMESPACE
  valueFrom: {fieldRef: {fieldPath: metadata.namespace}}
- name: K8S_NODE_NAME
  valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
- name: K8S_POD_IP
  valueFrom: {fieldRef: {fieldPath: status.podIP}}
- name: APP_NAME
  value: {{ $name | quote }}
- name: APP_VERSION
  value: {{ toString $v.image.tag | quote }}
- name: API_VERSION
  value: {{ $v.service.version | quote }}
- name: TENANT_ID
  value: {{ $v.tenant | default "" | quote }}
- name: ENVIRONMENT
  value: {{ $v.environment | quote }}
- name: PORT
  value: {{ $v.service.containerPort | quote }}
{{- /* ---------------- OpenTelemetry ---------------- */}}
- name: OTEL_SERVICE_NAME
  value: {{ $v.apm.serviceName | default $fullname | quote }}
- name: OTEL_RESOURCE_ATTRIBUTES
  value: {{ printf "service.namespace=%s,service.version=%s,deployment.environment=%s,deployment.environment.name=%s,tenant.id=%s,api.version=%s,k8s.namespace.name=$(K8S_NAMESPACE),k8s.pod.name=$(K8S_POD_NAME),k8s.node.name=$(K8S_NODE_NAME)" .Release.Namespace (toString $v.image.tag) $v.environment $v.environment $tenant $v.service.version | quote }}
{{- if $v.apm.enabled }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ $v.apm.endpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: {{ $v.apm.protocol | quote }}
- name: OTEL_TRACES_EXPORTER
  value: otlp
- name: OTEL_METRICS_EXPORTER
  value: {{ $v.apm.metricsExporter | quote }}
- name: OTEL_LOGS_EXPORTER
  value: {{ $v.apm.logsExporter | quote }}
- name: OTEL_PROPAGATORS
  value: tracecontext,baggage
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: {{ toString $v.apm.samplingRatio | quote }}
{{- else }}
- name: OTEL_SDK_DISABLED
  value: "true"
{{- end }}
{{- /* ---------------- Language tuning ---------------- */}}
{{- if eq $lang "java" }}
{{- $opts := list (printf "-XX:MaxRAMPercentage=%v" $v.tuning.java.maxRAMPercentage) "-XX:+UseG1GC" "-XX:+ExitOnOutOfMemoryError" "-Djava.io.tmpdir=/tmp" }}
{{- if $agent }}{{ $opts = append $opts (printf "-javaagent:%s/javaagent.jar" $ld.agent.mountPath) }}{{ end }}
{{- if $v.tuning.java.extraOptions }}{{ $opts = append $opts $v.tuning.java.extraOptions }}{{ end }}
- name: JAVA_TOOL_OPTIONS
  value: {{ join " " $opts | quote }}
- name: SERVER_PORT
  value: {{ $v.service.containerPort | quote }}
{{- if $v.apm.enabled }}
- name: OTEL_INSTRUMENTATION_COMMON_DEFAULT_ENABLED
  value: "true"
- name: OTEL_INSTRUMENTATION_LOGBACK_MDC_ADD_BAGGAGE
  value: "true"
{{- end }}
{{- else if eq $lang "dotnet" }}
- name: ASPNETCORE_URLS
  value: {{ printf "http://+:%v" $v.service.containerPort | quote }}
- name: ASPNETCORE_FORWARDEDHEADERS_ENABLED
  value: "true"
- name: DOTNET_gcServer
  value: {{ ternary "1" "0" (ne $v.tuning.dotnet.gcServer false) | quote }}
- name: DOTNET_GCHeapHardLimitPercent
  value: {{ printf "0x%X" (int $v.tuning.dotnet.gcHeapHardLimitPercent) | quote }}
{{- if $v.tuning.dotnet.gcDynamicAdaptation }}
- name: DOTNET_GCDynamicAdaptationMode
  value: "1"
{{- end }}
{{- if $agent }}
{{- $home := $ld.agent.mountPath }}
- name: OTEL_DOTNET_AUTO_HOME
  value: {{ $home | quote }}
- name: CORECLR_ENABLE_PROFILING
  value: "1"
- name: CORECLR_PROFILER
  value: "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
- name: CORECLR_PROFILER_PATH
  value: {{ printf "%s/%s/OpenTelemetry.AutoInstrumentation.Native.so" $home $v.apm.dotnetRuntimeIdentifier | quote }}
- name: DOTNET_ADDITIONAL_DEPS
  value: {{ printf "%s/AdditionalDeps" $home | quote }}
- name: DOTNET_SHARED_STORE
  value: {{ printf "%s/store" $home | quote }}
- name: DOTNET_STARTUP_HOOKS
  value: {{ printf "%s/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll" $home | quote }}
{{- end }}
{{- if $v.apm.enabled }}
- name: OTEL_DOTNET_AUTO_TRACES_ENABLED
  value: "true"
- name: OTEL_DOTNET_AUTO_METRICS_ENABLED
  value: {{ ne $v.apm.metricsExporter "none" | quote }}
- name: OTEL_DOTNET_AUTO_LOGS_ENABLED
  value: {{ ne $v.apm.logsExporter "none" | quote }}
- name: OTEL_DOTNET_AUTO_LOGS_INCLUDE_FORMATTED_MESSAGE
  value: "true"
- name: OTEL_DOTNET_AUTO_TRACES_ADDITIONAL_SOURCES
  value: {{ printf "%s.*" (title $name) | quote }}
{{- end }}
{{- else if eq $lang "python" }}
{{- $workers := int $v.tuning.python.webConcurrency }}
{{- if le $workers 0 }}
{{- $workers = add1 (div (mul 2 (int (include "microservice.cpuMillis" .))) 1000) | int }}
{{- $workers = min $workers (int $v.tuning.python.maxWorkers) | int }}
{{- $workers = max $workers 1 | int }}
{{- end }}
- name: PYTHONUNBUFFERED
  value: "1"
- name: PYTHONDONTWRITEBYTECODE
  value: "1"
- name: WEB_CONCURRENCY
  value: {{ $workers | quote }}
- name: PROMETHEUS_MULTIPROC_DIR
  value: /tmp/prometheus-multiproc
{{- if $v.apm.enabled }}
- name: OTEL_PYTHON_LOG_CORRELATION
  value: "true"
- name: OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED
  value: "true"
- name: OTEL_PYTHON_EXCLUDED_URLS
  value: "health/.*,metrics"
- name: OTEL_PYTHON_LOG_LEVEL
  value: info
{{- end }}
{{- if $agent }}
- name: PYTHONPATH
  value: {{ printf "%s/opentelemetry/instrumentation/auto_instrumentation:%s" $ld.agent.mountPath $ld.agent.mountPath | quote }}
{{- end }}
{{- end }}
{{- /* ---------------- Dependencies ---------------- */}}
{{- $d := $v.dependencies }}
{{- $e := $v.endpoints }}
{{- if $d.postgres.enabled }}
{{- $db := include "microservice.pgDatabase" . }}
- name: DB_HOST
  value: {{ ternary $e.postgres.pooler $e.postgres.rw (ne $d.postgres.pooler false) | quote }}
- name: DB_HOST_RO
  value: {{ $e.postgres.ro | quote }}
- name: DB_PORT
  value: {{ $e.postgres.port | quote }}
- name: DB_NAME
  value: {{ $db | quote }}
- name: DB_USER
  value: {{ $d.postgres.user | default $db | quote }}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $d.postgres.passwordSecret | default $secret }}
      key: {{ $d.postgres.passwordKey | default "DB_PASSWORD" }}
- name: DB_POOLED
  value: {{ ne $d.postgres.pooler false | quote }}
{{- end }}
{{- if $d.redis.enabled }}
- name: REDIS_HOST
  value: {{ $e.redis.host | quote }}
- name: REDIS_PORT
  value: {{ $e.redis.port | quote }}
- name: REDIS_DB
  value: {{ $d.redis.db | default 0 | quote }}
- name: REDIS_KEY_PREFIX
  value: {{ $d.redis.keyPrefix | default (printf "%s:%s:" $tenant $name) | quote }}
- name: REDIS_SENTINELS
  value: {{ $e.redis.sentinel | quote }}
- name: REDIS_SENTINEL_MASTER
  value: {{ $e.redis.sentinelMaster | quote }}
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $d.redis.passwordSecret | default $secret }}
      key: {{ $d.redis.passwordKey | default "REDIS_PASSWORD" }}
{{- end }}
{{- if $d.rabbitmq.enabled }}
- name: RABBITMQ_HOST
  value: {{ $e.rabbitmq.host | quote }}
- name: RABBITMQ_PORT
  value: {{ $e.rabbitmq.port | quote }}
- name: RABBITMQ_VHOST
  value: {{ $d.rabbitmq.vhost | default "/" | quote }}
- name: RABBITMQ_USER
  value: {{ $d.rabbitmq.user | default (ternary (printf "%s-%s" $v.tenant $name) $name (ne ($v.tenant | default "") "")) | quote }}
- name: RABBITMQ_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $d.rabbitmq.passwordSecret | default $secret }}
      key: {{ $d.rabbitmq.passwordKey | default "RABBITMQ_PASSWORD" }}
{{- end }}
{{- if $d.kafka.enabled }}
{{- $prefix := $d.kafka.topicPrefix | default (ternary (printf "%s." $v.tenant) "" (ne ($v.tenant | default "") "")) }}
- name: KAFKA_BOOTSTRAP_SERVERS
  value: {{ ternary $e.kafka.bootstrapTls $e.kafka.bootstrap (eq $d.kafka.tls true) | quote }}
- name: KAFKA_SECURITY_PROTOCOL
  value: {{ ternary "SSL" "PLAINTEXT" (eq $d.kafka.tls true) | quote }}
- name: KAFKA_TOPIC_PREFIX
  value: {{ $prefix | quote }}
- name: KAFKA_CONSUMER_GROUP
  value: {{ printf "%s%s" $prefix $fullname | quote }}
- name: KAFKA_CLIENT_ID
  value: "$(K8S_POD_NAME)"
{{- end }}
{{- end -}}

{{/* Final env list: standard env minus names overridden by .Values.env, then .Values.env. */}}
{{- define "microservice.env" -}}
{{- $user := list -}}
{{- if .Values.env -}}{{- $user = tpl (toYaml .Values.env) . | fromYamlArray -}}{{- end -}}
{{- $names := list -}}
{{- range $user -}}{{- $names = append $names .name -}}{{- end -}}
{{- $out := list -}}
{{- range (include "microservice.stdEnv" . | fromYamlArray) -}}
{{- if not (has .name $names) -}}{{- $out = append $out . -}}{{- end -}}
{{- end -}}
{{- toYaml (concat $out $user) -}}
{{- end -}}

{{/* =====================================================================
     Pod template (shared by Rollout and Deployment)
     ===================================================================== */}}
{{- define "microservice.podTemplate" -}}
{{- $v := .Values -}}
{{- $fullname := include "microservice.fullname" . -}}
{{- $name := include "microservice.name" . -}}
{{- $ld := include "microservice.languageDefaults" . | fromYaml -}}
{{- $agent := include "microservice.agentInjected" . -}}
{{- $hashKey := ternary "rollouts-pod-template-hash" "pod-template-hash" (eq $v.rollout.enabled true) -}}
{{- $uidStartup := include "microservice.startupUid" . | int -}}
metadata:
  labels:
    {{- include "microservice.podLabels" . | nindent 4 }}
  annotations:
    kubectl.kubernetes.io/default-container: {{ $name }}
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    prometheus.io/scrape: "true"
    prometheus.io/port: {{ $v.service.containerPort | quote }}
    prometheus.io/path: {{ $v.serviceMonitor.path | quote }}
    {{- if $v.istio.enabled }}
    {{- $p := $v.istio.proxy }}
    sidecar.istio.io/proxyCPU: {{ $p.cpu | quote }}
    sidecar.istio.io/proxyMemory: {{ $p.memory | quote }}
    {{- with $p.cpuLimit }}
    sidecar.istio.io/proxyCPULimit: {{ . | quote }}
    {{- end }}
    {{- with $p.memoryLimit }}
    sidecar.istio.io/proxyMemoryLimit: {{ . | quote }}
    {{- end }}
    proxy.istio.io/config: |
      holdApplicationUntilProxyStarts: {{ $p.holdApplicationUntilProxyStarts }}
      terminationDrainDuration: {{ $p.terminationDrainDuration }}
      {{- with $p.statsInclusionRegexps }}
      proxyStatsMatcher:
        inclusionRegexps:
          {{- toYaml . | nindent 10 }}
      {{- end }}
    {{- end }}
    {{- with $v.podAnnotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  serviceAccountName: {{ include "microservice.serviceAccountName" . }}
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
    {{- include "microservice.podSecurityContext" . | nindent 4 }}
  {{- $hasInit := or $agent (and $v.startup.waitForDependencies (include "microservice.dependencyEndpoints" . | trim)) $v.startup.migrations.enabled $v.initContainers }}
  {{- if $hasInit }}
  initContainers:
    {{- if $agent }}
    {{- $img := index $v.apm.agentImages $v.language }}
    - name: otel-agent
      image: {{ printf "%s:%s" $img.repository (toString $img.tag) }}
      imagePullPolicy: IfNotPresent
      command: {{ toJson $ld.agent.command }}
      securityContext:
        {{- include "microservice.containerSecurityContext" (dict "uid" 10001) | nindent 8 }}
      resources:
        requests: {cpu: 10m, memory: 32Mi}
        limits: {memory: 128Mi}
      volumeMounts:
        - name: {{ $ld.agent.volume }}
          mountPath: {{ $ld.agent.mountPath }}
    {{- end }}
    {{- if $v.startup.waitForDependencies }}
    {{- range (include "microservice.dependencyEndpoints" . | fromYamlArray) }}
    - name: wait-for-{{ .name }}
      image: {{ include "microservice.startupImage" $ }}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c"]
      args:
        - |
          end=$(( $(date +%s) + {{ int $v.startup.timeoutSeconds }} ))
          until nc -z -w 2 {{ .host }} {{ .port }}; do
            if [ "$(date +%s)" -ge "$end" ]; then
              echo "timeout after {{ int $v.startup.timeoutSeconds }}s waiting for {{ .name }} at {{ .host }}:{{ .port }}"; exit 1
            fi
            echo "waiting for {{ .name }} at {{ .host }}:{{ .port }}"; sleep 2
          done
          echo "{{ .name }} is reachable"
      securityContext:
        {{- include "microservice.containerSecurityContext" (dict "uid" $uidStartup) | nindent 8 }}
      resources:
        {{- toYaml $v.startup.resources | nindent 8 }}
    {{- end }}
    {{- end }}
    {{- if $v.startup.migrations.enabled }}
    - name: migrations
      image: {{ include "microservice.image" . }}
      imagePullPolicy: {{ $v.image.pullPolicy }}
      command: {{ required "startup.migrations.command is required when migrations are enabled" $v.startup.migrations.command | toJson }}
      {{- with $v.startup.migrations.args }}
      args: {{ toJson . }}
      {{- end }}
      {{- include "microservice.envBlock" . | nindent 6 }}
      securityContext:
        {{- include "microservice.containerSecurityContext" (dict "uid" $uidStartup) | nindent 8 }}
      resources:
        {{- toYaml $v.resources | nindent 8 }}
      volumeMounts:
        {{- include "microservice.volumeMounts" . | nindent 8 }}
    {{- end }}
    {{- with $v.initContainers }}
    {{- tpl (toYaml .) $ | nindent 4 }}
    {{- end }}
  {{- end }}
  containers:
    - name: {{ $name }}
      image: {{ include "microservice.image" . }}
      imagePullPolicy: {{ $v.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ $v.service.containerPort }}
          protocol: TCP
      {{- include "microservice.envBlock" . | nindent 6 }}
      startupProbe:
        {{- include "microservice.probe" (dict "probe" $v.probes.startup "lang" $ld.probes.startup "path" "/health/startup") | nindent 8 }}
      livenessProbe:
        {{- include "microservice.probe" (dict "probe" $v.probes.liveness "lang" $ld.probes.liveness "path" "/health/live") | nindent 8 }}
      readinessProbe:
        {{- include "microservice.probe" (dict "probe" $v.probes.readiness "lang" $ld.probes.readiness "path" "/health/ready") | nindent 8 }}
      lifecycle:
        preStop:
          {{- if and (semverCompare ">=1.30-0" .Capabilities.KubeVersion.Version) (ne $v.lifecycle.preStopMode "exec") }}
          # native sleep action: works with distroless/chiseled images that ship no shell
          sleep:
            seconds: {{ int $v.lifecycle.preStopSleepSeconds }}
          {{- else }}
          exec:
            command: ["sh", "-c", "sleep {{ int $v.lifecycle.preStopSleepSeconds }}"]
          {{- end }}
      securityContext:
        {{- include "microservice.containerSecurityContext" (dict "uid" 10001) | nindent 8 }}
      resources:
        {{- toYaml $v.resources | nindent 8 }}
      volumeMounts:
        {{- include "microservice.volumeMounts" . | nindent 8 }}
    {{- with $v.sidecars }}
    {{- tpl (toYaml .) $ | nindent 4 }}
    {{- end }}
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 512Mi
    {{- if eq $v.language "python" }}
    - name: prometheus-multiproc
      emptyDir:
        sizeLimit: 64Mi
    {{- end }}
    {{- if $agent }}
    - name: {{ $ld.agent.volume }}
      emptyDir:
        sizeLimit: 512Mi
    {{- end }}
    {{- with $v.extraVolumes }}
    {{- tpl (toYaml .) $ | nindent 4 }}
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
                {{- include "microservice.selectorLabels" . | nindent 16 }}
    {{- end }}
  {{- if $v.topologySpread.enabled }}
  topologySpreadConstraints:
    - maxSkew: {{ $v.topologySpread.maxSkew | default 1 }}
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: {{ $v.topologySpread.zoneWhenUnsatisfiable | default "ScheduleAnyway" }}
      labelSelector:
        matchLabels:
          {{- include "microservice.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [{{ $hashKey }}]
    - maxSkew: {{ $v.topologySpread.maxSkew | default 1 }}
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: {{ $v.topologySpread.hostnameWhenUnsatisfiable | default "ScheduleAnyway" }}
      labelSelector:
        matchLabels:
          {{- include "microservice.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [{{ $hashKey }}]
  {{- end }}
{{- end -}}

{{/* env + envFrom block shared by the app and the migrations container */}}
{{- define "microservice.envBlock" -}}
env:
  {{- include "microservice.env" . | nindent 2 }}
envFrom:
  - configMapRef:
      name: {{ include "microservice.configName" . }}
  {{- if .Values.externalSecret.enabled }}
  - secretRef:
      name: {{ include "microservice.secretName" . }}
  {{- end }}
  {{- with .Values.envFrom }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end -}}

{{- define "microservice.volumeMounts" -}}
{{- $ld := include "microservice.languageDefaults" . | fromYaml -}}
- name: tmp
  mountPath: /tmp
{{- if eq .Values.language "python" }}
- name: prometheus-multiproc
  mountPath: /tmp/prometheus-multiproc
{{- end }}
{{- if include "microservice.agentInjected" . }}
- name: {{ $ld.agent.volume }}
  mountPath: {{ $ld.agent.mountPath }}
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{ tpl (toYaml .) $ }}
{{- end }}
{{- end -}}

{{/* Names of the KongPlugins attached to the Ingress (chart-managed + user supplied). */}}
{{- define "microservice.kongPlugins" -}}
{{- $f := include "microservice.fullname" . -}}
{{- $k := .Values.kong -}}
{{- $p := list -}}
{{- if $k.correlationId.enabled }}{{ $p = append $p (printf "%s-correlation-id" $f) }}{{ end -}}
{{- if eq $k.auth "jwt" }}{{ $p = append $p (printf "%s-jwt" $f) }}{{ end -}}
{{- if $k.rateLimit.enabled }}{{ $p = append $p (printf "%s-rate-limit" $f) }}{{ end -}}
{{- if .Values.tenant }}{{ $p = append $p (printf "%s-tenant-header" $f) }}{{ end -}}
{{- if $k.responseTransformer.enabled }}{{ $p = append $p (printf "%s-response-headers" $f) }}{{ end -}}
{{- if $k.prometheus.enabled }}{{ $p = append $p (printf "%s-prometheus" $f) }}{{ end -}}
{{- if $k.opentelemetry.enabled }}{{ $p = append $p (printf "%s-otel" $f) }}{{ end -}}
{{- $p = concat $p ($k.plugins | default list) -}}
{{- join "," $p -}}
{{- end -}}
