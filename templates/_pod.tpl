{{/* repository@digest when a digest is set, repository:tag otherwise. */}}
{{- define "chart-base.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository (toString .Values.image.tag) -}}
{{- end -}}
{{- end -}}

{{- define "chart-base.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "chart-base.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{/*
Pod spec shared by Deployment, CronJob and Job.
Usage: include "chart-base.podSpec" (dict "ctx" $ "restartPolicy" "Never")
Deployment-only parts (preStop, topology spread) are rendered only for deployments.
*/}}
{{- define "chart-base.podSpec" -}}
{{- $ := .ctx -}}
{{- $fullname := include "chart-base.fullname" $ -}}
{{- $isDeployment := eq $.Values.workload.type "deployment" -}}
serviceAccountName: {{ include "chart-base.serviceAccountName" $ }}
automountServiceAccountToken: {{ $.Values.serviceAccount.automountToken }}
{{- with .restartPolicy }}
restartPolicy: {{ . }}
{{- end }}
{{- with $.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  {{- toYaml $.Values.podSecurityContext | nindent 2 }}
terminationGracePeriodSeconds: {{ $.Values.terminationGracePeriodSeconds }}
containers:
  - name: {{ include "chart-base.component" $ }}
    image: {{ include "chart-base.image" $ | quote }}
    imagePullPolicy: {{ $.Values.image.pullPolicy }}
    {{- with $.Values.command }}
    command:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $.Values.args }}
    args:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $.Values.ports }}
    ports:
      {{- range . }}
      - name: {{ .name }}
        containerPort: {{ .containerPort }}
        protocol: TCP
      {{- end }}
    {{- end }}
    {{- if or $.Values.config $.Values.externalSecret.enabled }}
    envFrom:
      {{- if $.Values.config }}
      - configMapRef:
          name: {{ $fullname }}-env
      {{- end }}
      {{- if $.Values.externalSecret.enabled }}
      - secretRef:
          name: {{ $fullname }}-secrets
      {{- end }}
    {{- end }}
    {{- with $.Values.probes.startup }}
    startupProbe:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $.Values.probes.liveness }}
    livenessProbe:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- with $.Values.probes.readiness }}
    readinessProbe:
      {{- toYaml . | nindent 6 }}
    {{- end }}
    {{- if and $isDeployment (gt (int $.Values.preStopSleepSeconds) 0) }}
    lifecycle:
      preStop:
        sleep:
          seconds: {{ $.Values.preStopSleepSeconds }}
    {{- end }}
    resources:
      {{- toYaml $.Values.resources | nindent 6 }}
    securityContext:
      {{- toYaml $.Values.securityContext | nindent 6 }}
    volumeMounts:
      - name: tmp
        mountPath: /tmp
      {{- if $.Values.configFiles.files }}
      - name: config-files
        mountPath: {{ $.Values.configFiles.mountPath }}
        readOnly: true
      {{- end }}
volumes:
  - name: tmp
    emptyDir: {}
  {{- if $.Values.configFiles.files }}
  - name: config-files
    configMap:
      name: {{ $fullname }}-files
  {{- end }}
{{- with $.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if $isDeployment }}
{{- if kindIs "invalid" $.Values.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- range list "topology.kubernetes.io/zone" "kubernetes.io/hostname" }}
  - maxSkew: 1
    topologyKey: {{ . }}
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "chart-base.selectorLabels" $ | nindent 8 }}
    matchLabelKeys:
      - pod-template-hash
  {{- end }}
{{- else if $.Values.topologySpreadConstraints }}
topologySpreadConstraints:
  {{- toYaml $.Values.topologySpreadConstraints | nindent 2 }}
{{- end }}
{{- end }}
{{- end -}}
