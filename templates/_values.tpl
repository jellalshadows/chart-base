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
chart-base.holdsValue: "true" when a value holds something other than a map, at any depth: a value that is neither a
map nor null (false, 0 and "" included), or a map with such a value inside it; nothing for a null, {} or a map whose
maps are all empty, such as what chart-base.pruneNulls leaves of {rollingUpdate: {partition: null}}. It does not enter
lists: a list is a value. Renders nothing else.
Usage: {{- if include "chart-base.holdsValue" $v }}
*/}}
{{- define "chart-base.holdsValue" -}}
{{- if kindIs "map" . -}}
{{- $found := false -}}
{{- range $_, $v := . }}{{ if include "chart-base.holdsValue" $v }}{{ $found = true }}{{ end }}{{ end -}}
{{- if $found }}true{{ end -}}
{{- else if not (kindIs "invalid" .) }}true{{ end -}}
{{- end -}}

{{/*
chart-base.longRunning: "true" when workload.type keeps its pods running: deployment or statefulset (ADR-0071); nothing
for cronjob and job. The one test of what a Deployment and a StatefulSet share: the Service, the routes, the
autoscalers, the PodDisruptionBudget, the monitors, the built-in preStop sleep and the default topology spread, and
their guards. What has no StatefulSet equivalent (strategy, progressDeadlineSeconds) tests workload.type deployment.
Usage: {{- if include "chart-base.longRunning" . }}
*/}}
{{- define "chart-base.longRunning" -}}
{{- if has .Values.workload.type (list "deployment" "statefulset") }}true{{ end -}}
{{- end -}}

{{/*
chart-base.statefulset: fills the dict `out` with what templates/statefulset.yaml renders and templates/validate.yaml
checks of the statefulset block: out.members, the members that are set, by name, each without its null fields
(chart-base.pruneNulls on a deep copy, ADR-0070). A null or absent block (a --reuse-values upgrade from 1.5 or older
has none), a null member and a member left empty by its nulls, at every depth (chart-base.holdsValue: {},
{type: null}, {rollingUpdate: {partition: null}}), are not set: Kubernetes' default applies. A member that is set
keeps its empty maps (templates/validate.yaml rejects {type: OnDelete, rollingUpdate: {}}). The one reader of
.Values.statefulset.
Usage: {{- $s := dict }}{{- include "chart-base.statefulset" (dict "ctx" $ "out" $s) }}, then $s.members
*/}}
{{- define "chart-base.statefulset" -}}
{{- $block := deepCopy (.ctx.Values.statefulset | default dict) -}}
{{- include "chart-base.pruneNulls" $block -}}
{{- $members := dict -}}
{{- /* The rule is chart-base.holdsValue. The truthiness test before it is 1.6.0's, kept so no value that rendered then
fails now: the schema allows no member that it alone drops (podManagementPolicy is an enum, the others objects). */ -}}
{{- range $name, $member := $block }}{{ if and $member (include "chart-base.holdsValue" $member) }}{{ $_ := set $members $name $member }}{{ end }}{{ end -}}
{{- $_ := set .out "members" $members -}}
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
chart-base.mainEnv: fills the dict `out` with out.env, the main container's env without its nulls: chart-base.pruneNulls
on a deep copy of env (ADR-0070), so a null variable, a null source next to another one and a null optional field of a
source are absent. A value that is not a map is empty (the list form, which templates/validate.yaml rejects with its own
message). The one reader of the main container's env for the guards and the Reloader annotations; chart-base.env prunes
what it renders the same way.
Usage: {{- $m := dict }}{{- include "chart-base.mainEnv" (dict "ctx" $ "out" $m) }}, then range $m.env
*/}}
{{- define "chart-base.mainEnv" -}}
{{- $env := dict -}}
{{- if kindIs "map" .ctx.Values.env }}{{ $env = deepCopy .ctx.Values.env }}{{ end -}}
{{- include "chart-base.pruneNulls" $env -}}
{{- $_ := set .out "env" $env -}}
{{- end -}}

{{/*
chart-base.hasConfig: "true" when config (nil counts as empty) holds at least one key whose value is not null, nothing
otherwise (a null key is absent, ADR-0070). The only test for the <fullname>-env ConfigMap, its envFrom entry and
checksum/config-env.
Usage: {{- if include "chart-base.hasConfig" . }}
*/}}
{{- define "chart-base.hasConfig" -}}
{{- $config := deepCopy (.Values.config | default dict) -}}
{{- include "chart-base.pruneNulls" $config -}}
{{- if $config }}true{{ end -}}
{{- end -}}

{{/*
chart-base.chartEnvNames: sets out.names to the names of the variables the main container receives from the chart:
out.config, the keys of config whose value is not null (in <fullname>-env), and out.secret, the keys of <fullname>-secrets that the chart can see
while the Secret is injected (chart-base.externalSecret: delivered, while injected; none otherwise: a disabled block or
envFrom false injects nothing). The one list of the main container's duplicate guard (its env against it) and of the
inheritEnv guard of an init container or a sidecar (its env against it and the component's env), so that a change of
what the main container receives reaches both.
Usage: {{- $e := dict }}{{- include "chart-base.chartEnvNames" (dict "ctx" $ "out" $e) }}, then $e.names, $e.config, $e.secret
*/}}
{{- define "chart-base.chartEnvNames" -}}
{{- $config := list -}}
{{- $values := deepCopy (.ctx.Values.config | default dict) -}}
{{- include "chart-base.pruneNulls" $values -}}
{{- range $name, $_ := $values }}{{ $config = append $config $name }}{{ end -}}
{{- $es := dict }}{{ include "chart-base.externalSecret" (dict "ctx" .ctx "out" $es) -}}
{{- $secret := list -}}
{{- if $es.injected }}{{ $secret = $es.delivered }}{{ end -}}
{{- $_ := set .out "config" $config -}}
{{- $_ := set .out "secret" $secret -}}
{{- $_ := set .out "names" (concat $config $secret | uniq) -}}
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
the container's ports: the kubelet resolves the name among that container's ports only. The same rule for the httpGet
port of a lifecycle hook (kinds postStart and preStop, subject "hook", ADR-0060). Renders nothing; fails through
chart-base.fail. A probe or hook that is not a map is skipped, and so is a handler that is not a map (the schema types
every handler as a map or null, ADR-0059); a port that is not a string (a number) and the exec, grpc and sleep handlers
are not checked.
Usage: include "chart-base.validateProbePorts" (dict "ctx" $ "path" "probes" "probes" .Values.probes "portNames" <list of
the container's port names> "portsPath" "ports" "declared" <optional map> "kinds" <optional list> "subject" <optional>).
`path` and `portsPath` name the values in the messages; the note about the Service and the NetworkPolicy is printed only
for the main container (portsPath "ports"). `declared` maps a port name of another container of the pod to the values
that declare it (a sidecar's ports, the main container's): when the unresolved name is there, the message says where
(without it, the message is the same as before sidecars existed). `kinds` are the keys of `probes` to read (default
startup, liveness, readiness) and `subject` the word of the messages (default probe).
*/}}
{{- define "chart-base.validateProbePorts" -}}
{{- $note := "" -}}
{{- if eq .portsPath "ports" }}{{ $note = " (a ports entry also becomes a Service port when a Service is rendered, and is opened by networkPolicy.ingress.fromComponents/fromNamespaces)" }}{{ end -}}
{{- $subject := .subject | default "probe" -}}
{{- $probes := .probes | default dict -}}
{{- range $kind := .kinds | default (list "startup" "liveness" "readiness") -}}
{{- $probe := get $probes $kind -}}
{{- if kindIs "map" $probe -}}
{{- range $handler := list "httpGet" "tcpSocket" -}}
{{- if hasKey $probe $handler -}}
{{- $h := index $probe $handler -}}
{{- if kindIs "map" $h -}}
{{- if and (kindIs "string" $h.port) (not (has $h.port $.portNames)) -}}
{{- $where := "" -}}
{{- if hasKey ($.declared | default dict) $h.port }}{{ $where = printf " (%q is declared in %s: a %s resolves a port name only among the ports of its own container)" $h.port (index $.declared $h.port) $subject }}{{ end -}}
{{- include "chart-base.fail" (list $.ctx (printf "%s.%s.%s.port %q is not the name of an entry in %s%s: the kubelet cannot resolve it and never runs the %s. Use the port number, or declare the name in %s%s, or remove the %s" $.path $kind $handler $h.port $.portsPath $where $subject $.portsPath $note $subject)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
chart-base.validateRunAsRoot: a container that would run as UID 0 with runAsNonRoot: true fails, since the kubelet never
starts it. Each field is the container's, else the pod's (podSecurityContext), as Kubernetes applies them; a nil test,
never a truthiness test (0 and false are values). Renders nothing; fails through chart-base.fail. The one rule of the
main container and of every init container and sidecar (ADR-0060).
Usage: include "chart-base.validateRunAsRoot" (dict "ctx" $ "who" "sidecars.proxy" "securityContext" <the container's
security context, merged for an entry>)
*/}}
{{- define "chart-base.validateRunAsRoot" -}}
{{- $sc := .securityContext | default dict -}}
{{- $pod := .ctx.Values.podSecurityContext | default dict -}}
{{- $uid := $sc.runAsUser -}}
{{- if kindIs "invalid" $uid }}{{ $uid = $pod.runAsUser }}{{ end -}}
{{- $nonRoot := $sc.runAsNonRoot -}}
{{- if kindIs "invalid" $nonRoot }}{{ $nonRoot = $pod.runAsNonRoot }}{{ end -}}
{{- if and (eq (toString $nonRoot) "true") (not (kindIs "invalid" $uid)) (eq (toString $uid) "0") -}}
{{- include "chart-base.fail" (list .ctx (printf "%s would run as UID 0 with runAsNonRoot: true and the kubelet would never start it: set its securityContext.runAsUser to a non-zero UID, or securityContext.runAsNonRoot: false (Pod Security restricted then rejects the pod)" .who)) -}}
{{- end -}}
{{- end -}}
