{{- define "web.fullname" -}}
meridian-web
{{- end }}

{{- define "web.labels" -}}
helm.sh/chart: web
app.kubernetes.io/name: web
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: meridian
app.kubernetes.io/component: web
{{- end }}

{{- define "web.selectorLabels" -}}
app.kubernetes.io/name: web
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
