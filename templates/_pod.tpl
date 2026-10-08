{{/* repository@digest when a digest is set, repository:tag otherwise, for an image map: the main container's (.Values.image), an init container's or a sidecar's. */}}
{{- define "chart-base.image" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository (toString .tag) -}}
{{- end -}}
{{- end -}}

{{/*
chart-base.env: the items of a container's env from a map NAME -> {valueFrom: ...}, in key order: the one renderer of
the env of every container (the main container's, an init container's, a sidecar's), so that a later source of the
shared definition is rendered once for all. A literal (not a map) is never rendered: templates/validate.yaml rejects it.
Usage: {{- with include "chart-base.env" <map> | trim }} env: {{- . | nindent <n> }} {{- end }}
*/}}
{{- define "chart-base.env" -}}
{{- range $name, $ref := . }}
{{- if kindIs "map" $ref }}
- name: {{ $name | quote }}
  valueFrom:
    {{- toYaml $ref.valueFrom | nindent 4 }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
chart-base.envFrom: the items of the main container's envFrom: the imported sources (envFrom) first, then <fullname>-env
(config) and <fullname>-secrets (externalSecret), so that the component's own keys win on a duplicate. An init container
or a sidecar with inheritEnv: true gets exactly these.
Usage: {{- with include "chart-base.envFrom" $ | trim }} envFrom: {{- . | nindent <n> }} {{- end }}
*/}}
{{- define "chart-base.envFrom" -}}
{{- with .Values.envFrom }}
{{ toYaml . }}
{{- end }}
{{- if .Values.config }}
- configMapRef:
    name: {{ include "chart-base.fullname" . }}-env
{{- end }}
{{- if .Values.externalSecret.enabled }}
- secretRef:
    name: {{ include "chart-base.fullname" . }}-secrets
{{- end }}
{{- end -}}

{{/* The pods' ServiceAccount: the chart's (<fullname>), an existing one (serviceAccount.name), or the namespace's default. */}}
{{- define "chart-base.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "chart-base.fullname" . -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "default" -}}
{{- end -}}
{{- end -}}

{{/*
Pod spec shared by Deployment, CronJob and Job.
Usage: include "chart-base.podSpec" (dict "ctx" $ "restartPolicy" "Never")
Deployment-only parts (the built-in preStop sleep, topology spread) are rendered only for deployments.
*/}}
{{- define "chart-base.podSpec" -}}
{{- $ := .ctx -}}
{{- $fullname := include "chart-base.fullname" $ -}}
{{- $isDeployment := eq $.Values.workload.type "deployment" -}}
{{- $volumes := dict -}}
{{- include "chart-base.volumes" (dict "ctx" $ "out" $volumes) -}}
{{- $containers := dict -}}
{{- include "chart-base.containers" (dict "ctx" $ "out" $containers) -}}
{{- /* An existing ServiceAccount's name comes from values: quoted, so that a name such as `on` stays a string. */ -}}
{{- $serviceAccountName := include "chart-base.serviceAccountName" $ -}}
{{- if and (not $.Values.serviceAccount.create) $.Values.serviceAccount.name }}{{ $serviceAccountName = quote $serviceAccountName }}{{ end -}}
serviceAccountName: {{ $serviceAccountName }}
automountServiceAccountToken: {{ $.Values.serviceAccount.automountToken }}
enableServiceLinks: {{ $.Values.enableServiceLinks }}
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
{{- /* Init containers and sidecars, in start order (chart-base.containers). */}}
{{- if $containers.ordered }}
initContainers:
  {{- range $c := $containers.ordered }}
  {{- include "chart-base.entryContainer" (dict "ctx" $ "container" $c) | nindent 2 }}
  {{- end }}
{{- end }}
containers:
  - name: {{ include "chart-base.component" $ }}
    image: {{ include "chart-base.image" $.Values.image | quote }}
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
      - name: {{ .name | quote }}
        containerPort: {{ .containerPort }}
        protocol: TCP
      {{- end }}
    {{- end }}
    {{- with include "chart-base.env" ($.Values.env | default dict) | trim }}
    env:
      {{- . | nindent 6 }}
    {{- end }}
    {{- with include "chart-base.envFrom" $ | trim }}
    envFrom:
      {{- . | nindent 6 }}
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
    {{- $lifecycle := $.Values.lifecycle | default dict }}
    {{- $preStopSleep := and $isDeployment (gt (int $.Values.preStopSleepSeconds) 0) }}
    {{- if or $lifecycle $preStopSleep }}
    lifecycle:
      {{- with $lifecycle.postStart }}
      postStart:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- /* One preStop only: templates/validate.yaml rejects lifecycle.preStop with the built-in sleep on deployments. */}}
      {{- if $lifecycle.preStop }}
      preStop:
        {{- toYaml $lifecycle.preStop | nindent 8 }}
      {{- else if $preStopSleep }}
      preStop:
        sleep:
          seconds: {{ $.Values.preStopSleepSeconds }}
      {{- end }}
    {{- end }}
    {{- /* A null quantity (resources.limits.<k>, resources.requests.<k>) and limits: null mean absent: the API server would store a null as "0". */}}
    {{- $resources := deepCopy ($.Values.resources | default dict) }}
    {{- include "chart-base.pruneNulls" $resources }}
    resources:
      {{- toYaml $resources | nindent 6 }}
    securityContext:
      {{- toYaml $.Values.securityContext | nindent 6 }}
    volumeMounts:
      - name: tmp
        mountPath: /tmp
      {{- if include "chart-base.hasConfigFiles" $ }}
      - name: config-files
        mountPath: {{ $.Values.configFiles.mountPath | quote }}
        readOnly: true
      {{- end }}
      {{- range $name, $v := $volumes }}
      - name: {{ $name | quote }}
        mountPath: {{ $v.mountPath | quote }}
        {{- if hasKey $v "subPath" }}
        subPath: {{ $v.subPath | quote }}
        {{- end }}
        {{- /* A configMap or secret mount is read-only (the kubelet forces it), and so is a claim declared ReadOnlyMany. */}}
        {{- if or (eq $v.type "configMap") (eq $v.type "secret") (and (eq $v.type "persistentVolumeClaim") (eq ($v.claimAccessMode | default "ReadWriteOnce") "ReadOnlyMany")) }}
        readOnly: true
        {{- else if hasKey $v "readOnly" }}
        readOnly: {{ $v.readOnly }}
        {{- end }}
      {{- end }}
volumes:
  - name: tmp
    emptyDir: {}
  {{- if include "chart-base.hasConfigFiles" $ }}
  - name: config-files
    configMap:
      name: {{ $fullname }}-files
  {{- end }}
  {{- range $volumeName, $v := $volumes }}
  - name: {{ $volumeName | quote }}
    {{- include "chart-base.volumeSource" (dict "ctx" $ "volume" $v) | nindent 4 }}
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
{{- with $.Values.priorityClassName }}
priorityClassName: {{ . | quote }}
{{- end }}
{{- with $.Values.runtimeClassName }}
runtimeClassName: {{ . | quote }}
{{- end }}
{{- with $.Values.dnsConfig }}
dnsConfig:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with $.Values.hostAliases }}
hostAliases:
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
