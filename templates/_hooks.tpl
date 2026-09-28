{{/* helm.sh/hook value for workload.type job, from job.phase. */}}
{{- define "chart-base.jobHooks" -}}
{{- if eq .Values.job.phase "post-deploy" -}}
post-install,post-upgrade
{{- else -}}
pre-install,pre-upgrade
{{- end -}}
{{- end -}}

{{/*
Hook annotations for the support resources of a `job` component (ServiceAccount,
ConfigMaps, ExternalSecret): they must exist, with the NEW content, before the Job
runs (weight -10 < the Job's 0). Empty for any other workload type.
*/}}
{{- define "chart-base.supportHookAnnotations" -}}
{{- if eq .Values.workload.type "job" }}
helm.sh/hook: {{ include "chart-base.jobHooks" . }}
helm.sh/hook-weight: "-10"
helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded
{{- end }}
{{- end -}}
