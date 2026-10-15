{{/*
The HorizontalPodAutoscaler's helpers (templates/hpa.yaml). Internal, not a public API.
*/}}

{{/*
chart-base.utilizationMetric: one built-in utilization target of the HPA (autoscaling.targetCPUUtilizationPercentage,
targetMemoryUtilizationPercentage) as an item of spec.metrics: a pod-wide Resource metric when container is "", a
ContainerResource metric for that container otherwise. templates/hpa.yaml passes the main container's name when the
component has a non-null sidecar (chart-base.hasSidecars): the percentage then measures the main container against
its own requests, as it did before the sidecar existed (ADR-0052).
Usage: include "chart-base.utilizationMetric" (dict "name" "cpu" "percent" <value> "container" <name or "">) | nindent 4
*/}}
{{- define "chart-base.utilizationMetric" -}}
{{- if .container -}}
- type: ContainerResource
  containerResource:
    name: {{ .name }}
    container: {{ .container | quote }}
    target:
      type: Utilization
      averageUtilization: {{ .percent }}
{{- else -}}
- type: Resource
  resource:
    name: {{ .name }}
    target:
      type: Utilization
      averageUtilization: {{ .percent }}
{{- end -}}
{{- end -}}

{{/*
chart-base.scaleTargetRef: the workload an autoscaler of this component targets, as the three lines of a
scaleTargetRef: apps/v1, Deployment, <fullname>. The one writer of the target of the HorizontalPodAutoscaler
(templates/hpa.yaml) and of the ScaledObject (templates/scaledobject.yaml): another workload type changes this helper
alone.
Usage: scaleTargetRef: {{- include "chart-base.scaleTargetRef" . | nindent 4 }}
*/}}
{{- define "chart-base.scaleTargetRef" -}}
apiVersion: apps/v1
kind: Deployment
name: {{ include "chart-base.fullname" . }}
{{- end -}}
