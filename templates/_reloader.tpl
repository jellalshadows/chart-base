{{/*
Stakater Reloader annotations for things that change OUTSIDE the deploy: the ExternalSecret's
Secret and every Secret/ConfigMap referenced in env (valueFrom) or envFrom. The chart's own
ConfigMaps are NOT listed: they roll pods through checksum annotations inside the deploy.
Reloader splits the value on commas and matches each entry as an anchored regex, so names are
regex-quoted (a "." would otherwise match any character). Renders nothing when there is nothing to watch.
*/}}
{{- define "chart-base.reloaderAnnotations" -}}
{{- if .Values.reloadOnChange -}}
{{- $secrets := list -}}
{{- $configMaps := list -}}
{{- if .Values.externalSecret.enabled -}}
{{- $secrets = append $secrets (printf "%s-secrets" (include "chart-base.fullname" .)) -}}
{{- end -}}
{{- range $_, $ref := .Values.env -}}
{{- with $ref.valueFrom.secretKeyRef }}{{ $secrets = append $secrets .name }}{{ end -}}
{{- with $ref.valueFrom.configMapKeyRef }}{{ $configMaps = append $configMaps .name }}{{ end -}}
{{- end -}}
{{- range .Values.envFrom -}}
{{- with .secretRef }}{{ $secrets = append $secrets .name }}{{ end -}}
{{- with .configMapRef }}{{ $configMaps = append $configMaps .name }}{{ end -}}
{{- end -}}
{{- $quoted := list -}}
{{- range $secrets | uniq | sortAlpha }}{{ $quoted = append $quoted (regexQuoteMeta .) }}{{ end -}}
{{- with $quoted }}
secret.reloader.stakater.com/reload: {{ join "," . | quote }}
{{- end }}
{{- $quoted = list -}}
{{- range $configMaps | uniq | sortAlpha }}{{ $quoted = append $quoted (regexQuoteMeta .) }}{{ end -}}
{{- with $quoted }}
configmap.reloader.stakater.com/reload: {{ join "," . | quote }}
{{- end }}
{{- end -}}
{{- end -}}
