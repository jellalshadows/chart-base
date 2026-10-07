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
