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

{{/*
Object metadata labels: the chart's own keys, then commonLabels. helm.sh/chart hardcodes the chart name: with an alias,
.Chart.Name is the alias. The metadata.labels of every object, and the ExternalSecret's template.metadata.labels.
*/}}
{{- define "chart-base.labels" -}}
{{- include "chart-base.labelsWith" (dict "ctx" .) -}}
{{- end -}}

{{/*
chart-base.labelsWith: chart-base.labels with a per-object map (metrics.labels, prometheusRule.labels, an extra object's
metadata.labels) merged over commonLabels: the chart's own keys first, in their order, then one map with sorted keys, in
which the per-object value wins on a shared key. Neither map can hold a chart key (the schema rejects them).
Usage: include "chart-base.labelsWith" (dict "ctx" $ "labels" <a map, or nil>) | nindent 4
*/}}
{{- define "chart-base.labelsWith" -}}
{{ include "chart-base.baseLabels" .ctx }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
helm.sh/chart: {{ printf "chart-base-%s" .ctx.Chart.Version | replace "+" "_" }}
{{- with include "chart-base.overCommon" (dict "own" .labels "common" .ctx.Values.commonLabels) }}
{{ . }}
{{- end }}
{{- end -}}

{{/*
Pod template labels (the pod templates of the Deployment, the CronJob and the Job, and the CronJob's job template): the
base labels, then podLabels merged over commonLabels (podLabels wins on a shared key). helm.sh/chart and
app.kubernetes.io/managed-by are deliberately excluded (ADR-0010): only a values change changes this set.
*/}}
{{- define "chart-base.podLabels" -}}
{{ include "chart-base.baseLabels" . }}
{{- with include "chart-base.overCommon" (dict "own" .Values.podLabels "common" .Values.commonLabels) }}
{{ . }}
{{- end }}
{{- end -}}

{{/*
chart-base.overCommon: a per-object map (own) merged over a common map (common: commonLabels or commonAnnotations), as
YAML with sorted keys, or nothing when both are empty; nil counts as empty. The per-object value wins on a shared key,
an empty one ("") included: each per-object key is set over a deep copy of the common map (merge would fill an empty
per-object value from the common map), never into .Values (a later template would read the merged map).
Usage: include "chart-base.overCommon" (dict "own" <a map, or nil> "common" <a map, or nil>)
*/}}
{{- define "chart-base.overCommon" -}}
{{- $merged := deepCopy (.common | default dict) -}}
{{- range $k, $v := (.own | default dict) }}{{ $_ := set $merged $k $v }}{{ end -}}
{{- with $merged }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
chart-base.annotations: the annotations of an object's metadata, as the lines under its annotations key, or nothing:
the chart's own annotations first (own: the text a template rendered before 0.11.0, i.e. the hook annotations of
chart-base.supportHookAnnotations, or the Reloader annotations; "" when none), then the per-object map (object:
ingress.annotations, service.annotations, an extra object's metadata.annotations; nil when none) merged over
commonAnnotations (chart-base.overCommon: the per-object value wins). Only an object's metadata: a pod template, the
CronJob's job template, an ephemeral claim template and the ExternalSecret's template take no common annotation.
Usage: {{- with include "chart-base.annotations" (dict "ctx" $ "own" <text> "object" <a map>) }} annotations: {{- . | nindent 4 }}
*/}}
{{- define "chart-base.annotations" -}}
{{- $own := .own | default "" -}}
{{- $merged := include "chart-base.overCommon" (dict "own" .object "common" .ctx.Values.commonAnnotations) -}}
{{- $own -}}
{{- if and $own $merged }}{{ "\n" }}{{ end -}}
{{- $merged -}}
{{- end -}}
