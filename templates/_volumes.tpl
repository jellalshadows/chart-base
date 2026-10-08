{{/*
Extra volumes (the values key volumes): the accessor and the rendering of a volume's source. Internal, not a public API.
*/}}

{{/*
chart-base.volumes: fills the dict `out` with the component's volumes, keyed by name: the non-null entries of volumes
(nil counts as empty), each without its null fields. It is chart-base.pruneNulls on a deep copy: a null entry and a null
field are absent, a list (items) is kept as written, and false, 0 and "" are values. The one accessor of every template
and guard that reads volumes: never read .Values.volumes elsewhere, test a field with hasKey (a nil test on the
accessor's entry), never with its truthiness, and never render an entry with toYaml.
Usage: {{- $volumes := dict }}{{- include "chart-base.volumes" (dict "ctx" $ "out" $volumes) }}, then range over $volumes
(in key order).
*/}}
{{- define "chart-base.volumes" -}}
{{- $all := deepCopy (.ctx.Values.volumes | default dict) -}}
{{- include "chart-base.pruneNulls" $all -}}
{{- range $name, $entry := $all }}{{ $_ := set $.out $name $entry }}{{ end -}}
{{- end -}}

{{/*
chart-base.volumeSource: the source of one volume (an entry of chart-base.volumes), each field rendered by name and every
string quoted: the lines that follow `- name:` in a pod's volumes. The claim template of an ephemeral volume is labelled
with chart-base.selectorLabels only: the template is part of the pod template, so this label set is a contract (another
label would roll every such pod on a chart bump).
Usage: include "chart-base.volumeSource" (dict "ctx" $ "volume" $entry) | nindent 4
*/}}
{{- define "chart-base.volumeSource" -}}
{{- $v := .volume -}}
{{- if eq $v.type "emptyDir" -}}
{{- if or (hasKey $v "medium") (hasKey $v "sizeLimit") -}}
emptyDir:
  {{- if hasKey $v "medium" }}
  medium: {{ $v.medium | quote }}
  {{- end }}
  {{- if hasKey $v "sizeLimit" }}
  sizeLimit: {{ $v.sizeLimit | quote }}
  {{- end }}
{{- else -}}
emptyDir: {}
{{- end -}}
{{- else if or (eq $v.type "configMap") (eq $v.type "secret") -}}
{{ $v.type }}:
  {{- if eq $v.type "configMap" }}
  name: {{ $v.name | quote }}
  {{- else }}
  secretName: {{ $v.secretName | quote }}
  {{- end }}
  {{- if hasKey $v "items" }}
  items:
    {{- range $item := $v.items }}
    - key: {{ $item.key | quote }}
      path: {{ $item.path | quote }}
      {{- if hasKey $item "mode" }}
      mode: {{ $item.mode | int64 }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if hasKey $v "defaultMode" }}
  defaultMode: {{ $v.defaultMode | int64 }}
  {{- end }}
  {{- if hasKey $v "optional" }}
  optional: {{ $v.optional }}
  {{- end }}
{{- else if eq $v.type "persistentVolumeClaim" -}}
persistentVolumeClaim:
  claimName: {{ $v.claimName | quote }}
  {{- /* The storage driver reads the source's flag only: it follows the declared ReadOnlyMany, never the mount. */}}
  {{- if eq ($v.claimAccessMode | default "ReadWriteOnce") "ReadOnlyMany" }}
  readOnly: true
  {{- end }}
{{- else if eq $v.type "ephemeral" -}}
ephemeral:
  volumeClaimTemplate:
    metadata:
      labels:
        {{- include "chart-base.selectorLabels" .ctx | nindent 8 }}
    spec:
      accessModes:
        - {{ $v.accessMode | default "ReadWriteOnce" | quote }}
      {{- if hasKey $v "storageClassName" }}
      storageClassName: {{ $v.storageClassName | quote }}
      {{- end }}
      resources:
        requests:
          storage: {{ $v.size | quote }}
{{- end -}}
{{- end -}}

{{/*
chart-base.volumeTypeFields: the fields each volume type owns besides type, mountPath, subPath and readOnly (every
type's), as YAML: the one table of the field-ownership guard (templates/validate.yaml). It holds exactly the fields of
values.schema.json's definitions.volume (pinned by tests/volumes_guards_test.yaml, one test per field).
Usage: include "chart-base.volumeTypeFields" . | fromYaml
*/}}
{{- define "chart-base.volumeTypeFields" -}}
emptyDir: [medium, sizeLimit]
configMap: [name, items, defaultMode, optional]
secret: [secretName, items, defaultMode, optional]
persistentVolumeClaim: [claimName, claimAccessMode]
ephemeral: [size, accessMode, storageClassName]
{{- end -}}

{{/*
chart-base.mainMounts: sets out.rows to the mounts the main container renders, in rendering order, each a dict: name,
path (as written), clean (chart-base.cleanPath of the path), source (emptyDir, configMap, secret, persistentVolumeClaim,
ephemeral), file (true for a subPath mount) and owner (how a message names the path). The chart's own tmp; config-files
only when chart-base.hasConfigFiles says it is rendered; then the entries of chart-base.volumes that have a mountPath
(a volume without one is mounted by an init container or a sidecar only). The one list every mount-path guard of the
main container reads (a later mount of the chart adds one row).
Usage: {{- $m := dict }}{{- include "chart-base.mainMounts" (dict "ctx" $ "volumes" $volumes "out" $m) }}, then range $m.rows
*/}}
{{- define "chart-base.mainMounts" -}}
{{- $rows := list (dict "name" "tmp" "path" "/tmp" "source" "emptyDir" "file" false "owner" "the chart's own tmp mount") -}}
{{- if include "chart-base.hasConfigFiles" .ctx -}}
{{- $rows = append $rows (dict "name" "config-files" "path" .ctx.Values.configFiles.mountPath "source" "configMap" "file" false "owner" "configFiles.mountPath") -}}
{{- end -}}
{{- range $name, $v := .volumes -}}
{{- if hasKey $v "mountPath" -}}
{{- $rows = append $rows (dict "name" $name "path" $v.mountPath "source" $v.type "file" (hasKey $v "subPath") "owner" (printf "volumes.%s.mountPath" $name)) -}}
{{- end -}}
{{- end -}}
{{- range $r := $rows }}{{ $_ := set $r "clean" (include "chart-base.cleanPath" $r.path) }}{{ end -}}
{{- $_ := set .out "rows" $rows -}}
{{- end -}}

{{/*
chart-base.readOnlyMount: "true" when every mount of the named volume is read-only, whatever the mount says (the kubelet
forces it): config-files, a configMap or secret entry of volumes, and a persistentVolumeClaim entry declared
ReadOnlyMany; nothing otherwise. Read by the mounts of init containers and sidecars and by their readOnly guard (the
main container's mounts state the same rule in templates/_pod.tpl).
Usage: include "chart-base.readOnlyMount" (dict "volumes" <the dict of chart-base.volumes> "name" <volume name>)
*/}}
{{- define "chart-base.readOnlyMount" -}}
{{- $v := index .volumes .name | default dict -}}
{{- if or (eq .name "config-files") (has ($v.type | default "") (list "configMap" "secret")) (and (eq ($v.type | default "") "persistentVolumeClaim") (eq ($v.claimAccessMode | default "ReadWriteOnce") "ReadOnlyMany")) }}true{{ end -}}
{{- end -}}
