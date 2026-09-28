{{/* Selector labels: IMMUTABLE once released (Deployment .spec.selector cannot change). */}}
{{- define "chart-base.selectorLabels" -}}
app.kubernetes.io/name: {{ include "chart-base.component" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* app.kubernetes.io/version from the image tag, sanitized to a valid label value. Empty if no tag. */}}
{{- define "chart-base.version" -}}
{{- $tag := .Values.image.tag | default "" | toString -}}
{{- $tag = regexReplaceAll "[^-A-Za-z0-9_.]" $tag "-" -}}
{{- $tag = $tag | trunc 63 | trimAll "-_." -}}
{{- $tag -}}
{{- end -}}

{{/* Labels shared by pod templates and object metadata (never helm.sh/chart). */}}
{{- define "chart-base.baseLabels" -}}
{{ include "chart-base.selectorLabels" . }}
app.kubernetes.io/part-of: {{ .Release.Name }}
app.kubernetes.io/component: {{ .Values.workload.type }}
{{- with include "chart-base.version" . }}
app.kubernetes.io/version: {{ . | quote }}
{{- end }}
{{- end -}}

{{/* Object metadata labels. helm.sh/chart hardcodes the chart name: with an alias, .Chart.Name is the alias. */}}
{{- define "chart-base.labels" -}}
{{ include "chart-base.baseLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "chart-base-%s" .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/* Pod template labels: base labels + podLabels. helm.sh/chart is deliberately excluded. */}}
{{- define "chart-base.podLabels" -}}
{{ include "chart-base.baseLabels" . }}
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}
