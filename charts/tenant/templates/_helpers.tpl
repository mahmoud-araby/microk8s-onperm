{{/*
=============================================================================
charts/tenant helpers
=============================================================================
*/}}

{{/* Tenant id. */}}
{{- define "tenant.name" -}}
{{- required "tenant.name is required" .Values.tenant.name -}}
{{- end -}}

{{/* "true" when the chart owns the namespace (landing zone), "" otherwise. */}}
{{- define "tenant.landingZone" -}}
{{- if kindIs "bool" .Values.tenant.landingZone -}}
{{- if .Values.tenant.landingZone }}true{{ end -}}
{{- else if eq .Values.tenant.tier "dedicated" -}}
true
{{- end -}}
{{- end -}}

{{/* Target namespace of the tenant's workloads / namespaced objects. */}}
{{- define "tenant.namespace" -}}
{{- if .Values.tenant.namespace -}}
{{- .Values.tenant.namespace -}}
{{- else if include "tenant.landingZone" . -}}
{{- printf "tenant-%s" (include "tenant.name" .) -}}
{{- else -}}
shared-services
{{- end -}}
{{- end -}}

{{/* Name prefix for objects rendered into a shared namespace (pooled tenants) - "" or "tenant-<name>-". */}}
{{- define "tenant.objectPrefix" -}}
{{- if not (include "tenant.landingZone" .) -}}
{{- printf "tenant-%s-" (include "tenant.name" .) -}}
{{- end -}}
{{- end -}}

{{/* SQL-safe identifier stem: hyphens -> underscores. */}}
{{- define "tenant.sqlName" -}}
{{- include "tenant.name" . | replace "-" "_" -}}
{{- end -}}

{{/* Public API host. */}}
{{- define "tenant.apiHost" -}}
{{- if .Values.endpoints.apiHost -}}
{{- .Values.endpoints.apiHost -}}
{{- else if eq .Values.tenant.tier "dedicated" -}}
{{- printf "%s.api.%s" (include "tenant.name" .) .Values.endpoints.domain -}}
{{- else -}}
{{- printf "api.%s" .Values.endpoints.domain -}}
{{- end -}}
{{- end -}}

{{/* Public frontend host. */}}
{{- define "tenant.appHost" -}}
{{- if .Values.endpoints.appHost -}}
{{- .Values.endpoints.appHost -}}
{{- else if eq .Values.tenant.tier "dedicated" -}}
{{- printf "%s.app.%s" (include "tenant.name" .) .Values.endpoints.domain -}}
{{- else -}}
{{- printf "app.%s" .Values.endpoints.domain -}}
{{- end -}}
{{- end -}}

{{/* Keycloak realm (defaults to the tenant name). */}}
{{- define "tenant.realm" -}}
{{- default (include "tenant.name" .) .Values.keycloak.realm -}}
{{- end -}}

{{- define "tenant.issuer" -}}
{{- printf "%s/realms/%s" (trimSuffix "/" .Values.keycloak.issuerBase) (include "tenant.realm" .) -}}
{{- end -}}

{{/* Common labels (conventions: app.kubernetes.io/*, platform.example.com/tenant). */}}
{{- define "tenant.labels" -}}
app.kubernetes.io/name: tenant
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/component: landing-zone
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
platform.example.com/tenant: {{ include "tenant.name" . }}
platform.example.com/tier: {{ .Values.tenant.tier }}
platform.example.com/environment: {{ .Values.tenant.environment }}
{{- with .Values.tenant.costCenter }}
platform.example.com/cost-center: {{ . | quote }}
{{- end }}
{{- with .Values.tenant.labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Common annotations. */}}
{{- define "tenant.annotations" -}}
platform.example.com/tenant-display-name: {{ .Values.tenant.displayName | default (include "tenant.name" .) | quote }}
platform.example.com/keycloak-realm: {{ include "tenant.realm" . | quote }}
{{- with .Values.tenant.annotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Normalise data.postgres.databases entries into a list of dicts:
{name, db (sql name), role, vaultPath, passwordKey, connectionLimit, crName}
Returned as YAML (use `fromYaml` + `.items`).
*/}}
{{- define "tenant.postgresDatabases" -}}
{{- $root := . -}}
{{- $items := list -}}
{{- range .Values.data.postgres.databases -}}
{{- $e := dict -}}
{{- if kindIs "string" . -}}
{{- $e = dict "name" . -}}
{{- else -}}
{{- $e = deepCopy . -}}
{{- end -}}
{{- $logical := required "data.postgres.databases[].name is required" $e.name -}}
{{- $sql := printf "%s_%s" (include "tenant.sqlName" $root) ($logical | replace "-" "_") -}}
{{- $_ := set $e "db" $sql -}}
{{- $_ := set $e "role" $sql -}}
{{- $_ := set $e "crName" (printf "%s-%s" (include "tenant.name" $root) $logical) -}}
{{- $_ := set $e "vaultPath" (default (printf "tenants/%s/%s" (include "tenant.name" $root) $logical) $e.vaultPath) -}}
{{- $_ := set $e "passwordKey" (default "DB_PASSWORD" $e.passwordKey) -}}
{{- $_ := set $e "connectionLimit" (default $root.Values.data.postgres.connectionLimit $e.connectionLimit) -}}
{{- $items = append $items $e -}}
{{- end -}}
{{ toYaml (dict "items" $items) }}
{{- end -}}

{{/* Standard hardened container securityContext (PSA restricted). */}}
{{- define "tenant.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: [ALL]
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/* Image reference helper: (dict "image" .Values.x.image) */}}
{{- define "tenant.image" -}}
{{- $i := .image -}}
{{- if $i.registry -}}
{{- printf "%s/%s:%s" $i.registry $i.repository ($i.tag | toString) -}}
{{- else -}}
{{- printf "%s:%s" $i.repository ($i.tag | toString) -}}
{{- end -}}
{{- end -}}
