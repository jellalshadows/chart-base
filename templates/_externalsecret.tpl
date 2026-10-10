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
- out.templateData: the non-null entries of externalSecret.template.data (template.data: null is none).
- out.templated: true when templateData has an entry. spec.target.template is rendered then, and only then: "templated"
  is never the presence of the map (an overlay that nulls its last entry leaves an empty map).
- out.mergePolicy: externalSecret.template.mergePolicy as written (Merge or Replace: required by the schema, never
  defaulted here).
- out.replace: true when the block is templated and mergePolicy is Replace: the keys of data and dataFrom are then only
  the template's inputs (External Secrets writes the templated keys alone).
- out.delivered: the keys that reach the Secret as far as the chart can see them, sorted: the keys of templateData, and
  the keys of data unless replace (a dataFrom entry brings keys the chart cannot see).
- out.injected: true when externalSecret.enabled and externalSecret.envFrom are both true: the Secret is injected whole
  (envFrom: secretRef <fullname>-secrets) into the main container, and into an entry with inheritEnv: true.
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
{{- $template := $values.template | default dict -}}
{{- $templateData := dict -}}
{{- if kindIs "map" $template.data }}{{ $templateData = deepCopy $template.data }}{{ end -}}
{{- include "chart-base.pruneNulls" $templateData -}}
{{- $_ := set .out "templateData" $templateData -}}
{{- $templated := gt (len $templateData) 0 -}}
{{- $_ := set .out "templated" $templated -}}
{{- $_ := set .out "mergePolicy" $template.mergePolicy -}}
{{- $_ := set .out "replace" (and $templated (eq (toString $template.mergePolicy) "Replace")) -}}
{{- $delivered := keys $templateData -}}
{{- if not .out.replace }}{{ $delivered = concat $delivered (keys $data) }}{{ end -}}
{{- $_ := set .out "delivered" ($delivered | uniq | sortAlpha) -}}
{{- $_ := set .out "injected" (and $values.enabled (eq (toString $values.envFrom) "true")) -}}
{{- end -}}
