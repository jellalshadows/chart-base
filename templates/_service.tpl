{{/* Port exposed by the Service for a `ports` entry. */}}
{{- define "chart-base.servicePort" -}}
{{- .servicePort | default .containerPort -}}
{{- end -}}

{{/* The Service port a route rule sends to: the `ports` entry named by the second argument, or the first entry when it is empty. */}}
{{- define "chart-base.routeBackendPort" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 1 -}}
{{- $entry := first $ctx.Values.ports -}}
{{- if $name -}}
{{- range $ctx.Values.ports }}{{ if eq .name (toString $name) }}{{ $entry = . }}{{ end }}{{ end -}}
{{- end -}}
{{- include "chart-base.servicePort" $entry -}}
{{- end -}}
