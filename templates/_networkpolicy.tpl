{{/*
Peers of the component's NetworkPolicy (templates/networkpolicy.yaml), each as a list item. Every string from
values is quoted: an alias or a namespace named `on` or `true` must stay a string.
*/}}

{{/*
The pods of a sibling component of the same release: its selector labels (the alias, the release).
Usage: include "chart-base.componentPeer" (list $ "<alias>")
*/}}
{{- define "chart-base.componentPeer" -}}
- podSelector:
    matchLabels:
      app.kubernetes.io/name: {{ index . 1 | quote }}
      app.kubernetes.io/instance: {{ (index . 0).Release.Name | quote }}
{{- end -}}

{{/*
Every pod of the namespaces named in the list, by the immutable label kubernetes.io/metadata.name.
Usage: include "chart-base.namespacePeer" (list "monitoring")
*/}}
{{- define "chart-base.namespacePeer" -}}
- namespaceSelector:
    matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values:
          {{- range . }}
          - {{ . | quote }}
          {{- end }}
{{- end -}}
