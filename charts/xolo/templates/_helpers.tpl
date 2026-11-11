{{- define "xolo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "xolo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "xolo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "xolo.labels" -}}
helm.sh/chart: {{ include "xolo.chart" . }}
{{ include "xolo.selectorLabels" . }}
app.kubernetes.io/version: {{ include "xolo.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "xolo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xolo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "xolo.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "xolo.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "xolo.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "xolo.secretName" -}}
{{- default (include "xolo.fullname" .) .Values.secrets.existingSecret }}
{{- end }}

{{- define "xolo.databaseSecretName" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecret }}
{{- else }}
{{- printf "%s-database" (include "xolo.fullname" .) }}
{{- end }}
{{- end }}

{{- define "xolo.databaseSecretKey" -}}
{{- if .Values.database.existingSecret }}
{{- .Values.database.existingSecretKey }}
{{- else -}}
dsn
{{- end }}
{{- end }}

{{/*
Refuses the configurations that cannot work with several replicas: they would
start, then lose data or sessions in ways much harder to diagnose.
*/}}
{{- define "xolo.validate" -}}
{{- $replicas := int .Values.replicaCount }}
{{- if .Values.autoscaling.enabled }}
{{- $replicas = int .Values.autoscaling.maxReplicas }}
{{- end }}
{{- if .Values.persistence.enabled }}
{{- if gt $replicas 1 }}
{{- fail "persistence.enabled (SQLite) supports a single replica: use PostgreSQL (database.dsn) to scale out" }}
{{- end }}
{{- else }}
{{- if and (not .Values.database.existingSecret) (not .Values.database.dsn) }}
{{- fail "database.dsn or database.existingSecret is required (a PostgreSQL DSN), or enable persistence for a single-replica SQLite install" }}
{{- end }}
{{- if and .Values.database.dsn (not (regexMatch "^(postgres|postgresql)://|(^|\\s)(host|dbname)=" .Values.database.dsn)) }}
{{- fail "database.dsn must address PostgreSQL when persistence is disabled: an SQLite file on an ephemeral pod filesystem is lost at each restart" }}
{{- end }}
{{- end }}
{{- if and .Values.provisionningAPI.enabled (not .Values.provisionningAPI.tlsSecret) }}
{{- fail "provisionningAPI.tlsSecret is required: the provisionning API only accepts mutual TLS" }}
{{- end }}
{{- if and .Values.provisionningAPI.enabled (not .Values.provisionningAPI.authorizedURIs) }}
{{- fail "provisionningAPI.authorizedURIs is required: no client certificate is authorized otherwise" }}
{{- end }}
{{- end }}
