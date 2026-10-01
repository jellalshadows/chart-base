{{/*
The single scrape endpoint of the component's monitor, as a list item. `port` is the NAME of an entry
in `ports` (checked by templates/validate.yaml). The port and the durations are quoted: a port named
`on` and a duration "0" must stay strings.
*/}}
{{- define "chart-base.metricsEndpoint" -}}
- port: {{ .Values.metrics.port | quote }}
  path: {{ .Values.metrics.path | quote }}
  {{- with .Values.metrics.interval }}
  interval: {{ . | quote }}
  {{- end }}
  {{- with .Values.metrics.scrapeTimeout }}
  scrapeTimeout: {{ . | quote }}
  {{- end }}
{{- end -}}
