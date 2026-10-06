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

{{/*
chart-base.validateProbePorts: a probe port given by NAME (httpGet.port, tcpSocket.port) must be the name of an entry of
the container's ports: the kubelet resolves the name among that container's ports only. Renders nothing; fails through
chart-base.fail. A probe that is not a map is skipped, and so is a nil handler; a port that is not a string (a number, an
absent port) and the exec and grpc handlers are not checked; a handler that is neither a map nor nil fails.
Usage: include "chart-base.validateProbePorts" (dict "ctx" $ "path" "probes" "probes" .Values.probes "portNames" <list of
the container's port names> "portsPath" "ports"). `path` and `portsPath` name the values in the messages; the note about
the Service and the NetworkPolicy is printed only for the main container (portsPath "ports").
*/}}
{{- define "chart-base.validateProbePorts" -}}
{{- $note := "" -}}
{{- if eq .portsPath "ports" }}{{ $note = " (a ports entry also becomes a Service port when a Service is rendered, and is opened by networkPolicy.ingress.fromComponents/fromNamespaces)" }}{{ end -}}
{{- $probes := .probes | default dict -}}
{{- range $kind := list "startup" "liveness" "readiness" -}}
{{- $probe := get $probes $kind -}}
{{- if kindIs "map" $probe -}}
{{- range $handler := list "httpGet" "tcpSocket" -}}
{{- if hasKey $probe $handler -}}
{{- $h := index $probe $handler -}}
{{- if kindIs "map" $h -}}
{{- if and (kindIs "string" $h.port) (not (has $h.port $.portNames)) -}}
{{- include "chart-base.fail" (list $.ctx (printf "%s.%s.%s.port %q is not the name of an entry in %s: the kubelet cannot resolve it and never runs the probe. Use the port number, or declare the name in %s%s, or remove the probe" $.path $kind $handler $h.port $.portsPath $.portsPath $note)) -}}
{{- end -}}
{{- else if not (kindIs "invalid" $h) -}}
{{- include "chart-base.fail" (list $.ctx (printf "%s.%s.%s must be a map, e.g. {port: 8080}, got %s" $.path $kind $handler (kindOf $h))) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
