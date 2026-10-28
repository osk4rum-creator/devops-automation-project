{{/*
Standard labels for every object of one component.
Usage: {{ include "app.labels" "backend" | nindent 4 }}
*/}}
{{- define "app.labels" -}}
app.kubernetes.io/name: {{ . }}
app.kubernetes.io/part-of: devops-app
app.kubernetes.io/managed-by: Helm
{{- end }}

{{/*
Selector labels: the SUBSET used to match pods. Must never change after the
first install (Kubernetes rejects selector changes on existing Deployments).
*/}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ . }}
{{- end }}

{{/*
Full image reference for a component, e.g. devops-app/backend:3f2a9c1
Usage: {{ include "app.image" (dict "root" $ "name" "backend") }}
*/}}
{{- define "app.image" -}}
{{ .root.Values.image.registry }}devops-app/{{ .name }}:{{ required "image.tag is required (use the git short SHA)" .root.Values.image.tag }}
{{- end }}
