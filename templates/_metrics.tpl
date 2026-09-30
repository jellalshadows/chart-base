{{/*
The single scrape endpoint of the component's monitor, as a list item. `port` is the NAME of an entry
in `ports` (checked by templates/validate.yaml). Durations are quoted: "0" must stay a string.
*/}}
{{- define "chart-base.metricsEndpoint" -}}
- port: {{ .Values.metrics.port }}
  path: {{ .Values.metrics.path | quote }}
  {{- with .Values.metrics.interval }}
  interval: {{ . | quote }}
  {{- end }}
  {{- with .Values.metrics.scrapeTimeout }}
  scrapeTimeout: {{ . | quote }}
  {{- end }}
{{- end -}}
