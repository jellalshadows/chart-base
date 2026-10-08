{{/*
Stakater Reloader annotations for things that change OUTSIDE the deploy: the ExternalSecret's
Secret and every Secret/ConfigMap referenced in env (valueFrom) or envFrom, or mounted by a configMap or secret
entry of volumes (read through chart-base.volumes: a null entry is not listed), or referenced in the env of an init
container or a sidecar (read through chart-base.containers: a null entry or variable is not listed; inheritEnv adds
nothing the main container's env does not list; a source other than secretKeyRef and configMapKeyRef is skipped,
whatever its key). The chart's own
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
{{- if kindIs "map" $ref -}}
{{- with $ref.valueFrom.secretKeyRef }}{{ $secrets = append $secrets .name }}{{ end -}}
{{- with $ref.valueFrom.configMapKeyRef }}{{ $configMaps = append $configMaps .name }}{{ end -}}
{{- end -}}
{{- end -}}
{{- range .Values.envFrom -}}
{{- with .secretRef }}{{ $secrets = append $secrets .name }}{{ end -}}
{{- with .configMapRef }}{{ $configMaps = append $configMaps .name }}{{ end -}}
{{- end -}}
{{- $containers := dict -}}
{{- include "chart-base.containers" (dict "ctx" . "out" $containers) -}}
{{- range $c := $containers.ordered -}}
{{- if kindIs "map" $c.entry.env -}}
{{- range $_, $entryRef := $c.entry.env -}}
{{- if kindIs "map" $entryRef -}}
{{- with $entryRef.valueFrom.secretKeyRef }}{{ $secrets = append $secrets .name }}{{ end -}}
{{- with $entryRef.valueFrom.configMapKeyRef }}{{ $configMaps = append $configMaps .name }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $volumes := dict -}}
{{- include "chart-base.volumes" (dict "ctx" . "out" $volumes) -}}
{{- range $_, $v := $volumes -}}
{{- if eq $v.type "secret" }}{{ $secrets = append $secrets $v.secretName }}{{ end -}}
{{- if eq $v.type "configMap" }}{{ $configMaps = append $configMaps $v.name }}{{ end -}}
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
