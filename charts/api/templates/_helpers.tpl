{{- define "api.fullname" -}}
meridian-api
{{- end }}

{{- define "api.labels" -}}
helm.sh/chart: api
app.kubernetes.io/name: api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: meridian
app.kubernetes.io/component: api
{{- end }}

{{- define "api.selectorLabels" -}}
app.kubernetes.io/name: api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
