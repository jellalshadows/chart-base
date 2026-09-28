{{/* Port exposed by the Service for a `ports` entry. */}}
{{- define "chart-base.servicePort" -}}
{{- .servicePort | default .containerPort -}}
{{- end -}}
