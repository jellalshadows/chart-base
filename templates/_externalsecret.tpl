{{/*
The component's ExternalSecret (the values key externalSecret): the one accessor of what its templates and guards read.
Internal, not a public API.
*/}}

{{/*
chart-base.externalSecret: fills the dict `out` with what the templates and guards read of externalSecret:
- out.data: the non-null entries of externalSecret.data, each without its null fields (chart-base.pruneNulls on a deep
  copy: data.<KEY>: null, and a null property, version or decodingStrategy, are absent). A value that is not a map
  counts as empty (nil: Helm hands one for a deleted default).
- out.dataFrom: externalSecret.dataFrom as written (a list: an overlay replaces it whole, and a null item or field is a
  schema error); nil counts as empty.
The one reader of externalSecret.data and externalSecret.dataFrom: never read them from .Values elsewhere, test a field
with hasKey on the pruned entry, never with its truthiness.
Usage: {{- $es := dict }}{{- include "chart-base.externalSecret" (dict "ctx" $ "out" $es) }}, then $es.data, $es.dataFrom
*/}}
{{- define "chart-base.externalSecret" -}}
{{- $values := .ctx.Values.externalSecret -}}
{{- $data := dict -}}
{{- if kindIs "map" $values.data }}{{ $data = deepCopy $values.data }}{{ end -}}
{{- include "chart-base.pruneNulls" $data -}}
{{- $_ := set .out "data" $data -}}
{{- $dataFrom := list -}}
{{- if kindIs "slice" $values.dataFrom }}{{ $dataFrom = $values.dataFrom }}{{ end -}}
{{- $_ := set .out "dataFrom" $dataFrom -}}
{{- end -}}
