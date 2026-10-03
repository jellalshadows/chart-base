{{/*
A RoleBinding of the component (templates/rolebinding.yaml), for the pods' ServiceAccount
(chart-base.serviceAccountName) in the release namespace. A binding's roleRef cannot change (the API server rejects
the update, and no Helm flag gets around it), so every binding's name is derived from what it references. On a job
component it is a hook of the Job's phase, like its Role and ServiceAccount (templates/_hooks.tpl). Every string from
values is quoted: a ClusterRole or an existing ServiceAccount named `on` or `true` must stay a string.
Usage: include "chart-base.roleBinding" (list $ "<binding name>" "Role|ClusterRole" "<role name>")
*/}}
{{- define "chart-base.roleBinding" -}}
{{- $ := index . 0 -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ index . 1 | quote }}
  labels:
    {{- include "chart-base.labels" $ | nindent 4 }}
  {{- with include "chart-base.supportHookAnnotations" $ }}
  annotations:
    {{- . | nindent 4 }}
  {{- end }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: {{ index . 2 }}
  name: {{ index . 3 | quote }}
subjects:
  - kind: ServiceAccount
    name: {{ include "chart-base.serviceAccountName" $ | quote }}
    namespace: {{ $.Release.Namespace | quote }}
{{- end -}}
