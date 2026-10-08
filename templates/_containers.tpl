{{/*
Init containers and sidecars (the values keys initContainers and sidecars): the accessor, the chart's hardened
security context default, and the rendering of one container. Internal, not a public API.
*/}}

{{/*
chart-base.containers: fills the dict `out` with the component's init containers and sidecars:
- out.initContainers and out.sidecars: the non-null entries of each map, each without its null fields at any depth
  (chart-base.pruneNulls on a deep copy; a list is kept as written). A value that is not a map counts as empty: a nil
  (Helm 3.22 hands one for a deleted default, and a --reuse-values upgrade from 0.7.x carries no such key) or the list
  that templates/validate.yaml rejects with its own message.
- out.ordered: every entry in start order, each a dict: name, kind ("initContainers" or "sidecars"), entry, and
  securityContext (chart-base.hardenedSecurityContext with the entry's own securityContext merged over it, field by
  field: mergeOverwrite keeps an explicit false, a list replaces the default's list).
The start order: order ascending (-1000 to 1000; an init container's default is 0, a sidecar's 1000), then the init
containers before the sidecars, then the name. The sort key is the text "<order + 1000, four digits>|<0 for an init
container, 1 for a sidecar>|<name>", sorted with sortAlpha: the offset 1000 is minus the schema's minimum
(definitions.containerOrder), so that the number is never negative (two negative numbers sort backwards as text). "No
order" is a hasKey test on the pruned entry, never Sprig's get (it returns "" for a missing key, which int64 reads as 0).
The one accessor of every template and guard that reads initContainers or sidecars: never read .Values.initContainers
or .Values.sidecars elsewhere (but the guard that rejects a list), test a field with hasKey, never with its
truthiness, and never render a raw entry with toYaml (only pruned sub-objects).
Usage: {{- $c := dict }}{{- include "chart-base.containers" (dict "ctx" $ "out" $c) }}, then range $c.ordered
*/}}
{{- define "chart-base.containers" -}}
{{- $keys := list -}}
{{- $byKey := dict -}}
{{- range $kind := list "initContainers" "sidecars" -}}
{{- $raw := index $.ctx.Values $kind -}}
{{- $all := dict -}}
{{- if kindIs "map" $raw }}{{ $all = deepCopy $raw }}{{ end -}}
{{- include "chart-base.pruneNulls" $all -}}
{{- $_ := set $.out $kind $all -}}
{{- range $name, $e := $all -}}
{{- $order := ternary 0 1000 (eq $kind "initContainers") -}}
{{- if hasKey $e "order" }}{{ $order = int64 $e.order }}{{ end -}}
{{- $key := printf "%04d|%d|%s" (add $order 1000) (ternary 0 1 (eq $kind "initContainers")) $name -}}
{{- $securityContext := mergeOverwrite (include "chart-base.hardenedSecurityContext" $.ctx | fromYaml) ($e.securityContext | default dict) -}}
{{- $_ := set $byKey $key (dict "name" $name "kind" $kind "entry" $e "securityContext" $securityContext) -}}
{{- $keys = append $keys $key -}}
{{- end -}}
{{- end -}}
{{- $ordered := list -}}
{{- range $key := sortAlpha $keys }}{{ $ordered = append $ordered (index $byKey $key) }}{{ end -}}
{{- $_ := set .out "ordered" $ordered -}}
{{- end -}}

{{/*
chart-base.hardenedSecurityContext: the container security context every init container and sidecar starts from, as
YAML: the four fields values.yaml ships for securityContext (with podSecurityContext, what Pod Security restricted
needs on every container). It exists twice, here and in values.yaml: tests/containers_test.yaml renders an entry
without an override next to the main container under default values and expects the same block. It is never the
component's securityContext value: a relaxation made for the main container does not reach another container.
Usage: include "chart-base.hardenedSecurityContext" . | fromYaml (a new map each time)
*/}}
{{- define "chart-base.hardenedSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
chart-base.entryContainer: one item of chart-base.containers' ordered list, rendered as an item of a pod's
initContainers: each field by name from the pruned entry, every string from values quoted, no empty list. A sidecar
gets restartPolicy: Always, which the chart writes (it is not a value).
Usage: include "chart-base.entryContainer" (dict "ctx" $ "container" <an item of ordered>) | nindent 2
*/}}
{{- define "chart-base.entryContainer" -}}
{{- $e := .container.entry -}}
{{- $pullPolicy := "IfNotPresent" -}}
{{- if hasKey $e.image "pullPolicy" }}{{ $pullPolicy = $e.image.pullPolicy }}{{ end -}}
- name: {{ .container.name | quote }}
  image: {{ include "chart-base.image" $e.image | quote }}
  imagePullPolicy: {{ $pullPolicy | quote }}
  {{- if eq .container.kind "sidecars" }}
  restartPolicy: Always
  {{- end }}
  {{- with $e.command }}
  command:
    {{- range $word := . }}
    - {{ $word | quote }}
    {{- end }}
  {{- end }}
  {{- with $e.args }}
  args:
    {{- range $arg := . }}
    - {{ $arg | quote }}
    {{- end }}
  {{- end }}
  resources:
    {{- toYaml $e.resources | nindent 4 }}
  securityContext:
    {{- toYaml .container.securityContext | nindent 4 }}
{{- end -}}
