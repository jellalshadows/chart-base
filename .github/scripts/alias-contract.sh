#!/usr/bin/env bash
# Verifies the consumption contract: chart-base used several times, with different
# aliases, as a dependency of a throwaway umbrella chart (nothing is committed).
# Usage: alias-contract.sh <path-to-chart-base>     Requires: helm, yq (mikefarah v4)
set -euo pipefail

chart_src="${1:?usage: alias-contract.sh <chart-dir>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Copy the chart next to the umbrellas and use a relative file:// path: Helm only treats
# file:// paths starting with "/" as absolute, which breaks on Windows drive letters.
mkdir -p "$work/chart-base"
cp -r "$chart_src"/Chart.yaml "$chart_src"/values.yaml "$chart_src"/values.schema.json "$chart_src"/templates "$work/chart-base/"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# $1 = umbrella dir, $2 = alias list (space separated)
make_umbrella() {
  local dir="$1"; shift
  mkdir -p "$dir/templates"
  {
    echo "apiVersion: v2"
    echo "name: vending"
    echo "version: 0.1.0"
    echo "dependencies:"
    for alias in "$@"; do
      echo "  - name: chart-base"
      echo "    version: \">=0.0.0-0\""
      echo "    repository: \"file://../chart-base\""
      echo "    alias: ${alias}"
      echo "    condition: ${alias}.enabled"
    done
  } > "$dir/Chart.yaml"
  # Helm 4 skips subchart schema validation in `helm lint` when templates/ is missing.
  echo "chart-base alias contract umbrella" > "$dir/templates/NOTES.txt"
  helm dependency update "$dir" > /dev/null
}

umbrella="$work/vending"
make_umbrella "$umbrella" api worker nightly-cleanup
cat > "$umbrella/values.yaml" <<'EOF'
global:
  onlyToggles: true
api:
  enabled: true
  image: {repository: ghcr.io/acme/sales, tag: "1.0.0"}
  resources: {requests: {cpu: 10m, memory: 32Mi}}
  httpRoute:
    enabled: true
    parentRefs: [{name: platform-gw, namespace: gateway}]
  metrics: {enabled: true}                  # a ServiceMonitor: api has a Service
  networkPolicy:
    enabled: true
    ingress:
      fromComponents: [worker]
      fromNamespaces: [envoy-gateway-system]   # where the Gateway's proxy pods run
      metricsFromNamespaces: [monitoring]
  serviceAccount: {automountToken: true}    # the chart creates vending-api
  rbac:
    rules:
      - {apiGroups: [coordination.k8s.io], resources: [leases], verbs: [get, list, watch, create, update, patch]}
    clusterRoles: [view]
worker:
  enabled: true
  image: {repository: ghcr.io/acme/sales, tag: "1.0.0"}
  resources: {requests: {cpu: 10m, memory: 32Mi}}
  service: {enabled: false}
  ports: [{name: metrics, containerPort: 9090}]
  metrics: {enabled: true, port: metrics}   # a PodMonitor: worker has no Service
  networkPolicy:
    enabled: true
    ingress: {metricsFromNamespaces: [monitoring]}
    egress:
      enabled: true
      toComponents: [api]
      dns: {podSelector: {dns.operator.openshift.io/daemonset-dns: default}}   # replaces the default
  serviceAccount: {create: false, name: vending-worker-sa, automountToken: true}   # an existing ServiceAccount
  rbac: {clusterRoles: [view]}
  env:                  # references and existing objects work under an alias
    POD_NAME: {valueFrom: {fieldRef: {fieldPath: metadata.name}}}
  envFrom:
    - configMapRef: {name: platform-endpoints, optional: true}
nightly-cleanup:        # hyphenated alias: values key, condition path and resource names
  enabled: true
  workload: {type: cronjob}
  image: {repository: ghcr.io/acme/sales, tag: "1.0.0"}
  resources: {requests: {cpu: 10m, memory: 32Mi}}
  cronjob: {schedule: "0 * * * *"}
EOF

# The namespace differs from the release name on purpose: a RoleBinding subject built from the release
# NAME instead of the release NAMESPACE must fail the rbac checks below.
render() { helm template vending "$umbrella" --namespace platform --kube-version 1.33.0 "$@"; }

rendered="$(render)" || fail "umbrella with valid values did not render"
pass "renders with global + <alias>.enabled keys present (schema tolerates reserved keys)"

names="$(echo "$rendered" | yq -N '.kind + "/" + .metadata.name' - | grep -v '^/$' | sort)"
dups="$(echo "$names" | uniq -d)"
[ -z "$dups" ] || fail "duplicated resources: $dups"
pass "no duplicated kind/name across aliases"

for expected in Deployment/vending-api Service/vending-api HTTPRoute/vending-api \
                Deployment/vending-worker CronJob/vending-nightly-cleanup ServiceAccount/vending-nightly-cleanup; do
  echo "$names" | grep -qx "$expected" || fail "missing $expected"
done
pass "resources are named <release>-<alias>"

echo "$names" | grep -qx "Service/vending-worker" && fail "worker must not have a Service"
pass "worker (service.enabled=false) renders no Service"

monitor_selects() { # kind name -> the <name>/<instance> labels its selector matches
  echo "$rendered" | yq -N "select(.kind == \"$1\" and .metadata.name == \"$2\") | .spec.selector.matchLabels | .[\"app.kubernetes.io/name\"] + \"/\" + .[\"app.kubernetes.io/instance\"]" -
}
[ "$(monitor_selects ServiceMonitor vending-api)" = "api/vending" ] || fail "api must get a ServiceMonitor that selects only its own Service"
[ "$(monitor_selects PodMonitor vending-worker)" = "worker/vending" ] || fail "worker must get a PodMonitor that selects only its own pods"
echo "$names" | grep -qxE "PodMonitor/vending-api|ServiceMonitor/vending-worker" && fail "one monitor kind per component: a ServiceMonitor with a Service, a PodMonitor without"
pass "metrics under an alias: a ServiceMonitor for api and a PodMonitor for worker, each selecting only its own component"

np_selects() { # name yq-path -> the <name>/<instance> labels of the selector at that path of the NetworkPolicy
  echo "$rendered" | yq -N "select(.kind == \"NetworkPolicy\" and .metadata.name == \"$1\") | $2 | .[\"app.kubernetes.io/name\"] + \"/\" + .[\"app.kubernetes.io/instance\"]" -
}
[ "$(np_selects vending-api .spec.podSelector.matchLabels)" = "api/vending" ] || fail "api's NetworkPolicy must select only api's pods"
[ "$(np_selects vending-worker .spec.podSelector.matchLabels)" = "worker/vending" ] || fail "worker's NetworkPolicy must select only worker's pods"
[ "$(np_selects vending-api '.spec.ingress[0].from[0].podSelector.matchLabels')" = "worker/vending" ] || fail "api's fromComponents [worker] must select worker's pods of this release"
[ "$(np_selects vending-worker '.spec.egress[1].to[0].podSelector.matchLabels')" = "api/vending" ] || fail "worker's toComponents [api] must select api's pods of this release"
echo "$names" | grep -qx "NetworkPolicy/vending-nightly-cleanup" && fail "nightly-cleanup has networkPolicy off: it must render no NetworkPolicy"
pass "networkPolicy under an alias: one NetworkPolicy per component, selecting only its own pods; fromComponents/toComponents select the sibling's pods"
dns_labels="$(echo "$rendered" | yq -N 'select(.kind == "NetworkPolicy" and .metadata.name == "vending-worker") | .spec.egress[0].to[0].podSelector.matchLabels | to_entries | map(.key + "=" + .value) | join(",")' -)"
[ "$dns_labels" = "dns.operator.openshift.io/daemonset-dns=default" ] || fail "worker's egress.dns.podSelector must replace the default DNS selector, not merge with it, got '$dns_labels'"
pass "an alias's egress.dns.podSelector replaces the default DNS selector (nothing is merged into it)"

rb_refs() { # RoleBinding name -> <roleRef kind>/<roleRef name> <subject kind>/<subject namespace>/<subject name>
  echo "$rendered" | yq -N "select(.kind == \"RoleBinding\" and .metadata.name == \"$1\") | .roleRef.kind + \"/\" + .roleRef.name + \" \" + .subjects[0].kind + \"/\" + .subjects[0].namespace + \"/\" + .subjects[0].name" -
}
got="$(rb_refs vending-api)"
[ "$got" = "Role/vending-api ServiceAccount/platform/vending-api" ] || fail "api's RoleBinding must bind its own Role to its own ServiceAccount in the release namespace, got '$got'"
got="$(rb_refs vending-api.view)"
[ "$got" = "ClusterRole/view ServiceAccount/platform/vending-api" ] || fail "api's RoleBinding to view must bind its own ServiceAccount in the release namespace, got '$got'"
got="$(rb_refs vending-worker.view)"
[ "$got" = "ClusterRole/view ServiceAccount/platform/vending-worker-sa" ] || fail "worker's RoleBinding to view must bind the existing ServiceAccount it names, in the release namespace, got '$got'"
api_rules="$(echo "$rendered" | yq -N -o=json -I=0 'select(.kind == "Role" and .metadata.name == "vending-api") | .rules' -)"
[ "$api_rules" = '[{"apiGroups":["coordination.k8s.io"],"resources":["leases"],"verbs":["get","list","watch","create","update","patch"]}]' ] \
  || fail "api's Role must hold exactly the umbrella's rules (the list replaces the default, nothing is merged into it), got '$api_rules'"
echo "$names" | grep -qxE "(ServiceAccount|Role|RoleBinding)/vending-worker" \
  && fail "worker names an existing ServiceAccount and binds only a ClusterRole: no ServiceAccount, Role or RoleBinding vending-worker"
echo "$names" | grep -qE "^(Role|RoleBinding)/vending-nightly-cleanup" && fail "nightly-cleanup has no rbac: it must render no Role or RoleBinding"
got="$(echo "$rendered" | yq -N 'select(.kind == "Deployment" and .metadata.name == "vending-worker") | .spec.template.spec | .serviceAccountName + " " + (.automountServiceAccountToken | tostring)' -)"
[ "$got" = "vending-worker-sa true" ] || fail "worker's pods must run as vending-worker-sa with the token mounted, got '$got'"
pass "rbac under an alias: each component's Role and RoleBindings (<release>-<alias>, <release>-<alias>.<ClusterRole>) bind its own ServiceAccount, the chart's or the existing one it names, in the release namespace"

worker_container='select(.kind == "Deployment" and .metadata.name == "vending-worker") | .spec.template.spec.containers[0]'
[ "$(echo "$rendered" | yq -N "$worker_container | .env[0].name" -)" = "POD_NAME" ] || fail "worker must render the env reference"
[ "$(echo "$rendered" | yq -N "$worker_container | .envFrom[0].configMapRef.name" -)" = "platform-endpoints" ] || fail "worker must render the envFrom ConfigMap"
[ "$(echo "$rendered" | yq -N 'select(.kind == "Deployment" and .metadata.name == "vending-worker") | .metadata.annotations["configmap.reloader.stakater.com/reload"]' -)" = "platform-endpoints" ] || fail "worker must list the referenced ConfigMap for Reloader"
echo "$rendered" | yq -N 'select(.kind == "Deployment" and .metadata.name == "vending-api") | .metadata.annotations' - | grep -q reloader && fail "api references nothing and must have no Reloader annotation"
pass "env/envFrom work under an alias and stay inside it (Reloader lists only the worker's ConfigMap)"

chart_label="$(echo "$rendered" | yq -N 'select(.kind == "Deployment" and .metadata.name == "vending-api") | .metadata.labels["helm.sh/chart"]' -)"
[[ "$chart_label" == chart-base-* ]] || fail "helm.sh/chart must be chart-base-<version>, got '$chart_label'"
pass "helm.sh/chart keeps the real chart name under an alias"

render --set worker.enabled=false | grep -q "name: vending-worker" && fail "worker.enabled=false must remove the component"
pass "<alias>.enabled=false removes the component"

if err="$(render --set nightly-cleanup.cronjob.schedule= 2>&1)"; then fail "empty cronjob.schedule must fail schema validation"; fi
echo "$err" | grep -q "nightly-cleanup" || fail "schema error must name the alias, got: $err"
pass "schema is enforced per alias ($(echo "$err" | head -1 | cut -c1-80)...)"

if err="$(render --set api.replica=3 2>&1)"; then fail "unknown key api.replica must fail (additionalProperties)"; fi
pass "typos under an alias fail"

# What a null does per values layer (docs/guides/consuming.md), on the Helm version that runs this script. Layers:
# U0 = the null in the umbrella's own values, nothing passed for the alias; U1 = the same plus --set api.replicas=2;
# F = an override file (-f) over the umbrella's values; S = --set. Helm 4.3 drops a null of the umbrella's own values in
# U0 only; Helm 3.22 keeps it in every layer. Values with a path go through files (Git Bash rewrites --set a=/x).
layers="$work/layers"
make_umbrella "$layers" api
helm4=false
case "$(helm version --short)" in v4.*) helm4=true ;; esac
lrender() { # <the umbrella's api values, indented 2 spaces> [helm args...]: renders the one-alias umbrella
  local own="$1"; shift
  case "$own" in *"resources:"*) ;; *) own="  resources: {requests: {cpu: 10m, memory: 32Mi}}
$own" ;; esac
  printf 'api:\n  image: {repository: ghcr.io/acme/sales, tag: "1.0.0"}\n%s\n' "$own" > "$layers/values.yaml"
  helm template vending "$layers" --namespace platform --kube-version 1.33.0 "$@" 2>&1 || true   # a failed render is checked by its output
}
over() { printf 'api:\n%s\n' "$1" > "$work/over.yaml"; echo "$work/over.yaml"; }
files_data() { echo "$1" | yq -N -o=json -I=0 'select(.kind == "ConfigMap" and .metadata.name == "vending-api-files") | .data' - 2>/dev/null || true; }
pod() { echo "$1" | yq -N -o=json -I=0 "select(.kind == \"Deployment\") | .spec.template$2" - 2>/dev/null || true; }
expect_fail() { # <rendered output> <text the error must contain> <what failed to fail>
  echo "$1" | grep -qF "$2" || fail "$3: expected an error with '$2', got: $(echo "$1" | grep -m1 'Error' || echo 'a render without that error')"
}

nulls='  configFiles:
    files:
      app.yaml: {top: keep, nested: {gone: null, stay: x}, bare: , empty: {}, blank: ""}
      retired.txt: null'
full='  configFiles:
    files:
      app.yaml: {top: keep, nested: {gone: g, stay: x}, bare: b, empty: {}, blank: ""}
      retired.txt: old'
want='{"app.yaml":"blank: \"\"\nempty: {}\nnested:\n  stay: x\ntop: keep"}'
bad_layers=""
[ "$(files_data "$(lrender "$nulls")")" = "$want" ] || bad_layers="$bad_layers U0"
[ "$(files_data "$(lrender "$nulls" --set api.replicas=2)")" = "$want" ] || bad_layers="$bad_layers U1"
f="$(over '  configFiles:
    files:
      app.yaml: {nested: {gone: null}, bare: }
      retired.txt: null')"
[ "$(files_data "$(lrender "$full" -f "$f")")" = "$want" ] || bad_layers="$bad_layers F"
[ "$(files_data "$(lrender "$full" --set 'api.configFiles.files.app\.yaml.nested.gone=null' --set 'api.configFiles.files.app\.yaml.bare=null' --set 'api.configFiles.files.retired\.txt=null')")" = "$want" ] || bad_layers="$bad_layers S"
[ -z "$bad_layers" ] || fail "configFiles: a null or bare key of a map-form file and a null file must be removed, the same in every layer, and the {} and \"\" next to them kept; differs in:$bad_layers"
pass "configFiles: a null key, a bare key and a null file are removed in U0, U1, F and S, and {} and \"\" are kept (the same bytes in every layer)"

for out in "$(lrender "$full" -f "$(over '  configFiles: {files: null}')")" "$(lrender '  configFiles: {files: {app.yaml: null, b.txt: null}}' --set api.replicas=2)"; do
  [ -z "$(files_data "$out")" ] || fail "configFiles: files null or every file null must render no ConfigMap vending-api-files"
  [ "$(pod "$out" '.spec.volumes | map(.name) | join(",")')" = '"tmp"' ] || fail "configFiles: files null or every file null must render only the tmp volume"
  [ "$(pod "$out" '.metadata.annotations["checksum/config-files"]')" = "null" ] || fail "configFiles: files null or every file null must render no checksum/config-files"
done
pass "configFiles: files null (F) and every file null (U1) render no ConfigMap, config-files volume, mount or checksum"

es_on='  externalSecret: {enabled: true, secretStoreRef: {name: vault}'
msg='chart-base[api]: externalSecret.enabled is true and externalSecret.data has no entry'
expect_fail "$(lrender "$es_on, data: null}")" "$msg" "externalSecret.data null in U0"
expect_fail "$(lrender "$es_on, data: null}" --set api.replicas=2)" "$msg" "externalSecret.data null in U1"
expect_fail "$(lrender "$es_on, data: {DB: {key: db}}}" -f "$(over '  externalSecret: {data: null}')")" "$msg" "externalSecret.data null in F"
pass "externalSecret: data null fails with the source guard's message in U0, U1 and F"

on='  externalSecret: {enabled: true, secretStoreRef: {name: vault}, data: {DB: {key: db}}}
  httpRoute: {enabled: true, parentRefs: [{name: gw}]}
  ingress: {enabled: true, className: nginx, hosts: [{host: a.example.com, paths: [{path: /, pathType: Prefix}]}]}'
expect_fail "$(lrender '  workload: {type: cronjob}
  cronjob: {schedule: "0 * * * *"}' --set api.cronjob.schedule=null)" "missing property 'schedule'" "cronjob.schedule null"
for k in externalSecret.secretStoreRef.kind externalSecret.secretStoreRef.name httpRoute.parentRefs ingress.hosts; do
  out="$(lrender "$on" --set "api.$k=null")"
  expect_fail "$out" "missing property '${k##*.}'" "$k null"
  echo "$out" | grep -q "^api:" || fail "the schema error for $k null must name the alias, got: $(echo "$out" | grep -m1 'Error' || echo 'no error')"
done
pass "when-enabled keys: a null cronjob.schedule, secretStoreRef.kind or .name, httpRoute.parentRefs or ingress.hosts fails, naming the alias"

expect_fail "$(lrender '  probes: {readiness: {tcpSocket: {port: http}}, liveness: {tcpSocket: {port: htpp}}}')" \
  'chart-base[api]: probes.liveness.tcpSocket.port "htpp" is not the name of an entry in ports' "a liveness probe on an undeclared port name"
pass "probes: a liveness port name that no ports entry declares fails, naming the alias"

limits='  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: null, memory: 64Mi}}'
set_limits='  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 64Mi}}'
bad_layers=""
for out in "$(lrender "$limits")" "$(lrender "$limits" --set api.replicas=2)" \
           "$(lrender "$set_limits" -f "$(over '  resources: {limits: {cpu: null}}')")" \
           "$(lrender "$set_limits" --set api.resources.limits.cpu=null)"; do
  [ "$(pod "$out" '.spec.containers[0].resources.limits')" = '{"memory":"64Mi"}' ] || bad_layers="$bad_layers x"
done
[ -z "$bad_layers" ] || fail "resources: a null limit must be removed in U0, U1, F and S"
pass "resources: a null limit is removed in U0, U1, F and S"

out="$(lrender '' --set 'api.configFiles.files.app\.yaml.id=9007199254740993' --set api.resources.limits.memory=9007199254740993)"
echo "$out" | grep -q 'id: 9007199254740993' || fail "configFiles: an integer above 2^53 from --set must stay exact in a map-form file (a JSON round trip would turn it into 9007199254740992)"
echo "$out" | grep -q 'memory: 9007199254740993' || fail "resources: an integer above 2^53 from --set must stay exact in a limit"
pass "configFiles and resources keep an integer above 2^53 from --set exact (9007199254740993): the pruned copies keep types and precision"

# One check per row of the null table of docs/guides/consuming.md: the -f layer, and U0, whose result depends on Helm.
out="$(lrender '  serviceAccount: {automountToken: null}')"
if $helm4; then [ "$(pod "$out" '.spec.automountServiceAccountToken')" = "false" ] || fail "row 1: Helm 4.3 U0 must keep the default automountToken"
else expect_fail "$out" "missing property 'automountToken'" "row 1, Helm 3 U0"; fi
expect_fail "$(lrender '' -f "$(over '  serviceAccount: {automountToken: null}')")" "missing property 'automountToken'" "row 1, F"
pass "null table row 1: a required chart default fails (F$($helm4 || echo ', U0')); Helm 4.3 U0 keeps the default"
sched='  workload: {type: cronjob}
  cronjob: {schedule: null}'
expect_fail "$(lrender "$sched")" "$($helm4 && echo "minLength: got 0, want 1" || echo "missing property 'schedule'")" "row 2, U0"
expect_fail "$(lrender '  workload: {type: cronjob}
  cronjob: {schedule: "0 * * * *"}' -f "$(over '  cronjob: {schedule: null}')")" "missing property 'schedule'" "row 2, F"
pass "null table row 2: a key an enabled block needs fails (F, U0); on Helm 4.3 U0 the default \"\" stays and fails the schema"
ro='.spec.containers[0].securityContext.readOnlyRootFilesystem'
out="$(lrender '  securityContext: {readOnlyRootFilesystem: null}')"
[ "$(pod "$out" "$ro")" = "$($helm4 && echo true || echo null)" ] || fail "row 3: U0 readOnlyRootFilesystem, got $(pod "$out" "$ro")"
[ "$(pod "$(lrender '' -f "$(over '  securityContext: {readOnlyRootFilesystem: null}')")" "$ro")" = "null" ] || fail "row 3: F must remove the default"
pass "null table row 3: another chart default is removed (F$($helm4 || echo ', U0')); Helm 4.3 U0 keeps it"
[ "$(pod "$(lrender '  nodeSelector: {disk: ssd}' -f "$(over '  nodeSelector: null')")" '.spec.nodeSelector')" = "null" ] || fail "row 4: F must clear nodeSelector"
[ "$(pod "$(lrender '  nodeSelector: null')" '.spec.nodeSelector')" = "null" ] || fail "row 4: U0 must leave no nodeSelector"
pass "null table row 4: a whole map of the chart's values.yaml is cleared (F, U0)"
expect_fail "$(lrender '' -f "$(over '  resources: {requests: null}')")" "got null, want object" "row 5, F"
expect_fail "$(lrender '  resources: {requests: null}')" "$($helm4 && echo "missing property 'requests'" || echo 'got null, want object')" "row 5, U0"
pass "null table row 5: a map that the chart's values.yaml does not define (resources.requests) fails the schema (F, U0)"
out="$(lrender '  nodeSelector: {disk: ssd, zone: null}')"
if $helm4; then [ "$(pod "$out" '.spec.nodeSelector')" = '{"disk":"ssd"}' ] || fail "row 6: Helm 4.3 U0 must drop the null entry"
else expect_fail "$out" "got null, want string" "row 6, Helm 3 U0"; fi
expect_fail "$(lrender '  nodeSelector: {disk: ssd, zone: z}' -f "$(over '  nodeSelector: {zone: null}')")" "got null, want string" "row 6, F"
pass "null table row 6: one entry of a typed map fails the schema (F$($helm4 || echo ', U0')); Helm 4.3 U0 drops it"
af='.spec.affinity'
[ "$(pod "$(lrender '  affinity: {nodeAffinity: null}')" "$af")" = "$($helm4 && echo null || echo '{"nodeAffinity":null}')" ] || fail "row 7: U0 affinity"
[ "$(pod "$(lrender '' -f "$(over '  affinity: {nodeAffinity: null}')")" "$af")" = '{"nodeAffinity":null}' ] || fail "row 7: F must render the null"
pass "null table row 7: a key inside a pass-through object is rendered as null (F$($helm4 || echo ', U0')); Helm 4.3 U0 drops it"

bad="$work/bad"
make_umbrella "$bad" Sales
cat > "$bad/values.yaml" <<'EOF'
Sales:
  image: {repository: ghcr.io/acme/sales, tag: "1.0.0"}
  resources: {requests: {cpu: 10m, memory: 32Mi}}
EOF
if err="$(helm template vending "$bad" --kube-version 1.33.0 2>&1)"; then fail "uppercase alias must fail"; fi
echo "$err" | grep -q "lowercase kebab-case" || fail "unexpected error for uppercase alias: $err"
pass "uppercase alias is rejected by the chart guard"

echo "alias contract: all checks passed"
