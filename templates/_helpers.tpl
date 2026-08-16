{{/*
Chart name.
*/}}
{{- define "meridian.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels for umbrella-level resources.
*/}}
{{- define "meridian.labels" -}}
helm.sh/chart: {{ include "meridian.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: meridian
{{- end }}

{{/*
Image pull secrets.
*/}}
{{- define "meridian.imagePullSecrets" -}}
{{- range .Values.global.imagePullSecrets }}
- name: {{ .name }}
{{- end }}
{{- end }}
