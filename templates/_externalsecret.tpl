{{/*
The component's ExternalSecret (the values key externalSecret): the one accessor of what its templates and guards read.
Internal, not a public API.
*/}}

{{/*
chart-base.externalSecret: fills the dict `out` with what the templates and guards read of externalSecret:
- out.data: the non-null entries of externalSecret.data, each without its null fields (chart-base.pruneNulls on a deep
  copy: data.<KEY>: null, and a null property, version or decodingStrategy, are absent). A value that is not a map
  counts as empty (nil: Helm hands one for a deleted default).
- out.dataFrom: externalSecret.dataFrom as written (a list: an overlay replaces it whole, and a null item or field is a
  schema error); nil counts as empty.
- out.templateData: the non-null entries of externalSecret.template.data (template.data: null is none).
- out.templated: true when templateData has an entry. spec.target.template is rendered then, and only then: "templated"
  is never the presence of the map (an overlay that nulls its last entry leaves an empty map).
- out.mergePolicy: externalSecret.template.mergePolicy as written (Merge or Replace: required by the schema, never
  defaulted here).
- out.replace: true when the block is templated and mergePolicy is Replace: the keys of data and dataFrom are then only
  the template's inputs (External Secrets writes the templated keys alone).
- out.delivered: the keys that reach the Secret as far as the chart can see them, sorted: the keys of templateData, and
  the keys of data unless replace (a dataFrom entry brings keys the chart cannot see).
- out.injected: true when externalSecret.enabled and externalSecret.envFrom are both true: the Secret is injected whole
  (envFrom: secretRef <fullname>-secrets) into the main container, and into an entry with inheritEnv: true.
- out.closed: true when the chart knows every key of the Secret: dataFrom is empty, or replace (the keys of a dataFrom
  entry are then template inputs only). A key named in the values (an externalSecretKeyRef, an item of the mount) is
  checked against delivered only then.
- out.mainMount: true when the block is enabled and externalSecret.mountPath is set: the main container mounts the
  volume external-secret there (mountPath, items and defaultMode are read nil-safe: Helm hands their null defaults as
  absent keys or as null, depending on the Helm version and the values files).
- out.mounted: true when the block is enabled and a container mounts the volume: the main container (mainMount), or a
  non-null init container or sidecar through a non-null volumeMounts.external-secret. The volume is rendered then, and
  only then.
- out.volume: the volume's source as an entry of chart-base.volumes (type secret, secretName <fullname>-secrets, items
  and defaultMode when set), rendered by chart-base.volumeSource and read by the entries' subPath guard.
The one reader of externalSecret.data and externalSecret.dataFrom: never read them from .Values elsewhere, and test a
field of a pruned entry with hasKey, never with its truthiness. One exception: data.<KEY>.property keeps its
truthiness test in templates/externalsecret.yaml (an empty property renders nothing, as before 0.9.0).
Usage: {{- $es := dict }}{{- include "chart-base.externalSecret" (dict "ctx" $ "out" $es) }}, then $es.data, $es.dataFrom
*/}}
{{- define "chart-base.externalSecret" -}}
{{- $values := .ctx.Values.externalSecret -}}
{{- $data := dict -}}
{{- if kindIs "map" $values.data }}{{ $data = deepCopy $values.data }}{{ end -}}
{{- include "chart-base.pruneNulls" $data -}}
{{- $_ := set .out "data" $data -}}
{{- $dataFrom := list -}}
{{- if kindIs "slice" $values.dataFrom }}{{ $dataFrom = $values.dataFrom }}{{ end -}}
{{- $_ := set .out "dataFrom" $dataFrom -}}
{{- $template := $values.template | default dict -}}
{{- $templateData := dict -}}
{{- if kindIs "map" $template.data }}{{ $templateData = deepCopy $template.data }}{{ end -}}
{{- include "chart-base.pruneNulls" $templateData -}}
{{- $_ := set .out "templateData" $templateData -}}
{{- $templated := gt (len $templateData) 0 -}}
{{- $_ := set .out "templated" $templated -}}
{{- $_ := set .out "mergePolicy" $template.mergePolicy -}}
{{- $_ := set .out "replace" (and $templated (eq (toString $template.mergePolicy) "Replace")) -}}
{{- $delivered := keys $templateData -}}
{{- if not .out.replace }}{{ $delivered = concat $delivered (keys $data) }}{{ end -}}
{{- $_ := set .out "delivered" ($delivered | uniq | sortAlpha) -}}
{{- $_ := set .out "injected" (and $values.enabled (eq (toString $values.envFrom) "true")) -}}
{{- $_ := set .out "closed" (or (not $dataFrom) .out.replace) -}}
{{- $mainMount := and $values.enabled (kindIs "string" $values.mountPath) -}}
{{- $_ := set .out "mainMount" $mainMount -}}
{{- $containers := dict -}}
{{- include "chart-base.containers" (dict "ctx" .ctx "out" $containers) -}}
{{- $entryMount := false -}}
{{- range $c := $containers.ordered }}{{ if hasKey ($c.entry.volumeMounts | default dict) "external-secret" }}{{ $entryMount = true }}{{ end }}{{ end -}}
{{- $_ := set .out "mounted" (and $values.enabled (or $mainMount $entryMount)) -}}
{{- $volume := dict "type" "secret" "secretName" (printf "%s-secrets" (include "chart-base.fullname" .ctx)) -}}
{{- if kindIs "slice" $values.items }}{{ $_ := set $volume "items" $values.items }}{{ end -}}
{{- if not (kindIs "invalid" $values.defaultMode) }}{{ $_ := set $volume "defaultMode" $values.defaultMode }}{{ end -}}
{{- $_ := set .out "volume" $volume -}}
{{- end -}}

{{/*
chart-base.notDelivered: the message for a key named in the values that is not a key of the Secret, shared by
env.<NAME>.valueFrom.externalSecretKeyRef.key, externalSecret.items[].key and the subPath of a mount of the volume
external-secret: one wording, with two variants under a templated Replace (only the keys of template.data reach the
Secret): one for a data key, which Replace keeps out of the Secret, and one for any other key. Renders the message
(the caller fails with it).
Usage: include "chart-base.notDelivered" (dict "es" <chart-base.externalSecret's dict> "what" "<values path>" "key" <key>)
Optional, for a caller with its own wording (the subPath): "written" (the value as written, quoted in the message;
default: key), "subject" (default: "is not a key of the Secret"), "remedy" (the remedy outside a templated Replace;
default: "correct it, or add it to externalSecret.data or externalSecret.template.data") and "correct" (how to correct
the value, the first remedy of the variant for any other key under a templated Replace; default: "correct it").
*/}}
{{- define "chart-base.notDelivered" -}}
{{- $written := .key }}{{ if hasKey . "written" }}{{ $written = .written }}{{ end -}}
{{- $subject := "is not a key of the Secret" }}{{ if hasKey . "subject" }}{{ $subject = .subject }}{{ end -}}
{{- $remedy := "correct it, or add it to externalSecret.data or externalSecret.template.data" }}{{ if hasKey . "remedy" }}{{ $remedy = .remedy }}{{ end -}}
{{- $correct := "correct it" }}{{ if hasKey . "correct" }}{{ $correct = .correct }}{{ end -}}
{{- if and .es.replace (hasKey .es.data .key) -}}
{{- printf "%s %q %s (its keys: %s): externalSecret.data.%s is only an input of the template, because externalSecret.template.mergePolicy is Replace; add the key to externalSecret.template.data, or set externalSecret.template.mergePolicy: Merge" .what $written $subject (join ", " .es.delivered) .key -}}
{{- else if .es.replace -}}
{{- printf "%s %q %s (its keys: %s): %s, or add it to externalSecret.template.data (externalSecret.template.mergePolicy is Replace: only the keys of externalSecret.template.data reach the Secret)" .what $written $subject (join ", " .es.delivered) $correct -}}
{{- else -}}
{{- printf "%s %q %s (its keys: %s): %s" .what $written $subject (join ", " .es.delivered) $remedy -}}
{{- end -}}
{{- end -}}
