{{/*
Helpers that read values for templates and guards; internal, not a public API.
*/}}

{{/*
chart-base.pruneNulls: removes, in place, every key whose value is null (a nil test, kindIs "invalid", never a
truthiness test) from a map the caller owns, and does the same inside every value that is a map, at any depth. It does
not enter lists: a list and everything inside it are kept as written. A map emptied by the removal stays an empty map;
every other value keeps its type and precision (false, 0, "", [], {}; an int64 from --set). Renders nothing.
Usage: {{- $m := deepCopy (<value> | default dict) -}}{{- include "chart-base.pruneNulls" $m -}}, then read $m.
Never pass .Values or a map inside it (later templates would read the pruned values), and never deepCopy a nil (the
render aborts).
*/}}
{{- define "chart-base.pruneNulls" -}}
{{- $m := . -}}
{{- range $k, $v := $m -}}
{{- if kindIs "invalid" $v -}}
{{- $_ := unset $m $k -}}
{{- else if kindIs "map" $v -}}
{{- include "chart-base.pruneNulls" $v -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
chart-base.hasConfigFiles: "true" when configFiles.files (nil counts as empty) holds at least one file whose value is
not null, nothing otherwise. A map-form file whose content is {} is a file. The only test for the <fullname>-files
ConfigMap, the config-files volume and mount, checksum/config-files and the pod template's annotations key.
Usage: {{- if include "chart-base.hasConfigFiles" . }}
*/}}
{{- define "chart-base.hasConfigFiles" -}}
{{- $found := false -}}
{{- range $name, $content := .Values.configFiles.files | default dict -}}
{{- if not (kindIs "invalid" $content) }}{{ $found = true }}{{ end -}}
{{- end -}}
{{- if $found }}true{{ end -}}
{{- end -}}

{{/*
chart-base.cleanPath: a path normalized as the kubelet normalizes a mount path (filepath.Clean("/" + path)), to COMPARE
paths only: never render it; the caller renders the original value with quote. Whitespace and # are kept.
Usage: include "chart-base.cleanPath" <path>
*/}}
{{- define "chart-base.cleanPath" -}}
{{- clean (print "/" .) -}}
{{- end -}}
