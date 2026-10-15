{{/*
KEDA (the values key keda): the one accessor of what templates/scaledobject.yaml and templates/validate.yaml read.
Internal, not a public API.
*/}}

{{/*
chart-base.keda: fills the dict `out` with what the templates and guards read of keda:
- out.keda: the block, or an empty dict when it is absent or null (keda: null from any values layer, or a
  --reuse-values upgrade from a release whose values have no keda key): KEDA is then off.
- out.triggers: the non-null entries of keda.triggers, each without its null fields at any depth (chart-base.pruneNulls
  on a deep copy: a null trigger, a null metricType, authenticationRef or authenticationRef.kind, a null useCachedMetrics
  and a null metadata key are absent; a list is kept as written). A value that is not a map counts as empty.
The one reader of keda.triggers: never read it from .Values elsewhere, test a field of an entry with hasKey, never with
its truthiness.
Usage: {{- $k := dict }}{{- include "chart-base.keda" (dict "ctx" $ "out" $k) }}, then $k.keda, $k.triggers
*/}}
{{- define "chart-base.keda" -}}
{{- $keda := .ctx.Values.keda | default dict -}}
{{- $triggers := dict -}}
{{- if kindIs "map" $keda.triggers }}{{ $triggers = deepCopy $keda.triggers }}{{ end -}}
{{- include "chart-base.pruneNulls" $triggers -}}
{{- $_ := set .out "keda" $keda -}}
{{- $_ := set .out "triggers" $triggers -}}
{{- end -}}
