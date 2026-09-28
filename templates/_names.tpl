{{/*
Internal helpers. Named templates are global in Helm, but ONLY values are the
public contract of chart-base: do not include these from other charts.
*/}}

{{/* Component name: the dependency alias (Helm sets .Chart.Name to the alias). */}}
{{- define "chart-base.component" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/* <release>-<component>, always (no `contains` shortcut, no truncation). */}}
{{- define "chart-base.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "chart-base.component" .) -}}
{{- end -}}

{{/* Fail with a message prefixed by the component. Usage: include "chart-base.fail" (list $ "msg") */}}
{{- define "chart-base.fail" -}}
{{- $ctx := index . 0 -}}
{{- fail (printf "chart-base[%s]: %s" (include "chart-base.component" $ctx) (index . 1)) -}}
{{- end -}}
