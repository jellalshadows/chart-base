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
worker:
  enabled: true
  image: {repository: ghcr.io/acme/sales, tag: "1.0.0"}
  resources: {requests: {cpu: 10m, memory: 32Mi}}
  service: {enabled: false}
  ports: []
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

render() { helm template vending "$umbrella" --namespace vending --kube-version 1.33.0 "$@"; }

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
