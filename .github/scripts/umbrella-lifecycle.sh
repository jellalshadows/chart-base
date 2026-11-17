#!/usr/bin/env bash
# The lifecycle of one umbrella with a Deployment, a CronJob and a Job alias (api, nightly, migrate) on the current kube
# context (the kind cluster of the CI e2e job, after e2e.sh), in a namespace that enforces Pod Security "restricted":
# install, [an upgrade to the candidate,] a values change, a rollback to revision 1, an uninstall. Each step checks in
# the cluster: the release's object set (helm get manifest), that every object of revision 1 keeps its uid (never
# recreated) and its selector, which steps ran the Job hook, and at the end that nothing of the release is left.
# Usage: umbrella-lifecycle.sh <chart-dir> [<from-chart-ref>]     Requires: kubectl, helm, yq (mikefarah v4)
#   <chart-dir>: the candidate chart. <from-chart-ref> (the validation campaign): the chart that revision 1 installs,
#   then upgraded to the candidate with the same values: an OCI reference with its version
#   (oci://ghcr.io/jellalshadows/charts/chart-base:0.11.0) or a chart directory. Without it, revision 1 is the
#   candidate. Helm-version neutral: the same flags on Helm 3.22 and 4.3.
set -euo pipefail

chart_dir="${1:?usage: umbrella-lifecycle.sh <chart-dir> [<from-chart-ref>]}"
from_ref="${2:-}"
ns=lifecycle release=life
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: umbrella lifecycle: $*" >&2
  helm history "$release" -n "$ns" >&2 || true
  kubectl get all,configmaps,serviceaccounts,networkpolicies,poddisruptionbudgets -n "$ns" >&2 || true
  kubectl get events -n "$ns" --sort-by=.lastTimestamp >&2 || true
  kubectl logs -n "$ns" "job/$release-migrate" --tail=20 >&2 || true
  exit 1
}
pass() { echo "ok - umbrella lifecycle: $*"; }

# Two umbrellas with the same name and values, one per chart: the candidate (copied next to it, a relative file://
# path, as alias-contract.sh does) and the chart of revision 1.
umbrella() { # <dir> <repository> <version>
  mkdir -p "$1/templates"
  {
    echo "apiVersion: v2"
    echo "name: lifecycle"
    echo "version: 0.1.0"
    echo "dependencies:"
    for alias in api nightly migrate; do
      echo "  - {name: chart-base, version: \"$3\", repository: \"$2\", alias: $alias}"
    done
  } > "$1/Chart.yaml"
  echo "umbrella lifecycle" > "$1/templates/NOTES.txt"
  helm dependency update "$1" > /dev/null || fail "helm dependency update of $1 (chart-base $3 from $2) failed"
}
copy_chart() { mkdir -p "$2" && cp -r "$1"/Chart.yaml "$1"/values.yaml "$1"/values.schema.json "$1"/templates "$2/"; }
copy_chart "$chart_dir" "$work/chart-base"
umbrella "$work/candidate" "file://../chart-base" ">=0.0.0-0"
if [ -z "$from_ref" ]; then
  first="$work/candidate" first_name="the candidate"
elif [ -d "$from_ref" ]; then
  copy_chart "$from_ref" "$work/from-chart"
  umbrella "$work/from" "file://../from-chart" ">=0.0.0-0"
  first="$work/from" first_name="chart-base $(yq '.version' "$from_ref/Chart.yaml") ($from_ref)"
elif [[ "$from_ref" =~ ^(oci://.+)/chart-base:([0-9][^/:]*)$ ]]; then
  umbrella "$work/from" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  first="$work/from" first_name="chart-base ${BASH_REMATCH[2]} ($from_ref)"
else
  fail "<from-chart-ref> must be oci://<registry>/<path>/chart-base:<version> or a chart directory, got '$from_ref'"
fi

cat > "$work/values.yaml" <<'EOF'
api:
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  args: ["netexec", "--http-port=8080"]
  resources: {requests: {cpu: 10m, memory: 16Mi}}
  config: {APP_MODE: v1}
nightly:
  workload: {type: cronjob}
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  command: ["sh", "-c", "echo nightly"]
  ports: []
  resources: {requests: {cpu: 10m, memory: 16Mi}}
  cronjob: {schedule: "0 3 1 1 *", suspend: true}
migrate:
  workload: {type: job}
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  command: ["sh", "-c", "echo migrated"]
  ports: []
  resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
# The values change: a config value (the api pods roll) and an extra object (the object set grows by one).
cat > "$work/change.yaml" <<'EOF'
api:
  config: {APP_MODE: v2}
  extraObjects:
    settings: {apiVersion: v1, kind: ConfigMap, data: {mode: v2}}
EOF
added="ConfigMap/$release-api.settings"

objects() { # <revision>: the release's objects, "<Kind>/<name>" sorted (hooks are not release objects)
  helm get manifest "$release" -n "$ns" --revision "$1" | yq -N 'select(.kind != null) | .kind + "/" + .metadata.name' | sort
}
state() { # <Kind/name>: [uid, selector] as JSON, read from the cluster
  kubectl get -n "$ns" "$1" -o yaml | yq -o=json -I=0 '[.metadata.uid, (.spec.selector // .spec.podSelector // null)]'
}
job_run() { kubectl get job -n "$ns" "$release-migrate" -o jsonpath='{.metadata.uid} {.status.succeeded}'; }
api_revision() { kubectl get deployment -n "$ns" "$release-api" -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}'; }
api_labels() { kubectl get deployment -n "$ns" "$release-api" -o yaml | yq -o=json -I=0 '.spec.template.metadata.labels'; }
# check <step> <expected objects>: the release's latest revision holds exactly those objects, each of them exists in the
# cluster, and every object of revision 1 kept its uid and selector.
check() {
  local step="$1" expected="$2" revision obj now got
  revision="$(helm history "$release" -n "$ns" -o yaml | yq '.[-1].revision')"
  got="$(objects "$revision")" || fail "$step: could not read the manifest of revision $revision"
  [ "$got" = "$expected" ] || fail "$step: revision $revision must hold exactly the objects
$expected
got
$got"
  while IFS= read -r obj; do
    kubectl get -n "$ns" "$obj" > /dev/null || fail "$step: $obj of revision $revision is not in the cluster"
  done <<< "$got"
  while read -r obj; do
    now="$(state "$obj")" || fail "$step: $obj of revision 1 is gone"
    [ "$now" = "${first_state[$obj]}" ] || fail "$step: $obj was recreated or changed its selector (uid and selector at revision 1: ${first_state[$obj]}, now: $now)"
  done <<< "$first_objects"
}

# Idempotent, so that the script reruns on one cluster (the namespace is kept at the end).
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - > /dev/null \
  || fail "could not create or update the namespace $ns"
kubectl label namespace "$ns" --overwrite \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest > /dev/null \
  || fail "could not label the namespace $ns for Pod Security restricted"

echo "== umbrella lifecycle: install ($first_name)"
helm install "$release" "$first" -n "$ns" -f "$work/values.yaml" --wait --timeout 5m || fail "the install of $first_name failed"
first_objects="$(objects 1)" || fail "install: could not read the manifest of revision 1"
declare -A first_state
while read -r obj; do
  first_state[$obj]="$(state "$obj")" || fail "install: $obj of revision 1 is not in the cluster"
done <<< "$first_objects"
for kind in Deployment/$release-api CronJob/$release-nightly ServiceAccount/$release-api; do
  [ -n "${first_state[$kind]:-}" ] || fail "install: revision 1 must hold $kind, got: $(tr '\n' ' ' <<< "$first_objects")"
done
run="$(job_run || true)"
[ "${run#* }" = 1 ] || fail "install: the pre-deploy Job hook $release-migrate must have succeeded once, got '$run' (uid succeeded)"
first_labels="$(api_labels)"
pass "install of $first_name: $(wc -l <<< "$first_objects" | tr -d ' ') objects, the Job hook ran"

if [ "$first" != "$work/candidate" ]; then
  echo "== umbrella lifecycle: upgrade to the candidate, same values"
  before="$(api_revision)"
  helm upgrade "$release" "$work/candidate" -n "$ns" -f "$work/values.yaml" --wait --timeout 5m \
    || fail "the upgrade from $first_name to the candidate failed"
  check "upgrade to the candidate" "$first_objects"
  now="$(job_run || true)"
  [ "${now#* }" = 1 ] && [ "${now% *}" != "${run% *}" ] || fail "upgrade to the candidate: the Job hook must run again (a new Job that succeeded), got '$now', before '$run'"
  run="$now"
  pass "upgrade from $first_name to the candidate: the same objects, uids and selectors; the Job hook ran; api's pod template revision $before -> $(api_revision)"
fi

echo "== umbrella lifecycle: a values change"
before="$(api_revision)"
helm upgrade "$release" "$work/candidate" -n "$ns" -f "$work/values.yaml" -f "$work/change.yaml" --wait --timeout 5m \
  || fail "the upgrade with a values change failed"
check "values change" "$(printf '%s\n%s\n' "$first_objects" "$added" | sort)"
mode="$(kubectl get -n "$ns" configmap "$release-api.settings" -o jsonpath='{.data.mode}' || true)"
[ "$mode" = v2 ] || fail "values change: the extra ConfigMap $release-api.settings must hold mode=v2, got '$mode'"
now="$(job_run || true)"
[ "${now#* }" = 1 ] && [ "${now% *}" != "${run% *}" ] || fail "values change: the Job hook must run again (a new Job that succeeded), got '$now', before '$run'"
run="$now"
after="$(api_revision)"
[ "$after" -gt "$before" ] || fail "values change: a config change must roll api (the checksum annotation), pod template revision $before -> $after"
pass "values change: $added added, uids and selectors kept, the Job hook ran, api rolled (revision $before -> $after)"

echo "== umbrella lifecycle: rollback to revision 1"
helm rollback "$release" 1 -n "$ns" --wait --timeout 5m || fail "the rollback to revision 1 failed"
check "rollback" "$first_objects"
gone="$(kubectl get -n "$ns" configmap "$release-api.settings" --ignore-not-found -o name)" || fail "rollback: could not look up $added"
[ -z "$gone" ] || fail "rollback: $added must be deleted (revision 1 has no extra object), it is still there"
[ "$(api_labels)" = "$first_labels" ] || fail "rollback: api's pod template labels must be revision 1's again, got $(api_labels), revision 1: $first_labels"
now="$(job_run || true)"
[ "$now" = "$run" ] || fail "rollback: chart-base's Job hooks are pre-install,pre-upgrade only, so a rollback runs none: the Job must be the previous one, got '$now', before '$run'"
pass "rollback to revision 1: its objects, uids, selectors and pod labels are back, $added is gone, no Job hook ran"

echo "== umbrella lifecycle: uninstall"
helm uninstall "$release" -n "$ns" || fail "the uninstall failed"
# Deletion is asynchronous (the garbage collector deletes the ReplicaSets and pods): poll every 2 s for up to 120 s.
# The Job hook stays: hooks are not release objects, so helm uninstall never deletes them (ADR-0007); its support
# objects deleted themselves when it succeeded (hook-succeeded).
kinds=deployments,replicasets,cronjobs,jobs,services,configmaps,secrets,serviceaccounts,networkpolicies,poddisruptionbudgets,horizontalpodautoscalers,roles,rolebindings
left=""
for _ in $(seq 1 60); do
  left="$(kubectl get "$kinds" -n "$ns" -l "app.kubernetes.io/instance=$release" -o name | sort | tr '\n' ' ')" \
    || fail "uninstall: could not list what is left of the release"
  [ "$left" = "job.batch/$release-migrate " ] && break
  sleep 2
done
[ "$left" = "job.batch/$release-migrate " ] || fail "uninstall: only the Job hook job.batch/$release-migrate may be left, got: $left"
kubectl delete job -n "$ns" "$release-migrate" --wait=true > /dev/null || fail "uninstall: could not delete the Job hook"
pass "uninstall: nothing of the release is left but the Job hook (not a release object, ADR-0007), deleted by this script"
