{{- define "feature-freeze.name" -}}
{{- printf "%s-feature-freeze-control" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- define "feature-freeze.labels" -}}
app.kubernetes.io/name: feature-freeze-control
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- define "feature-freeze.selectorLabels" -}}
app.kubernetes.io/name: feature-freeze-control
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
