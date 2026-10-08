#!/usr/bin/env bash
# Real install of every ci/ scenario on the current kube context (a kind cluster in CI):
# namespace enforcing Pod Security "restricted", Gateway API CRDs, External Secrets Operator
# with the fake provider, Prometheus Operator CRDs (no operator). Then an umbrella of three
# components in a namespace with a default-deny NetworkPolicy, probed with agnhost connect
# (kindnet enforces NetworkPolicy), and probed again once the default-deny is deleted. Then an
# umbrella of three components with RBAC (an existing ServiceAccount, a ClusterRole, a pre-deploy
# Job), checked with kubectl auth can-i and with API calls from their own pods. The cronjob, full and deployment
# scenarios also check extra volumes: an existing claim kept across CronJob runs, an ephemeral claim per pod, a tmpfs
# emptyDir, a Secret directory beneath the config-files mount, one ConfigMap key as a file, the Reloader feed, and two
# in-place strategy changes of a Deployment that mounts an existing claim.
# Usage: e2e.sh <chart-dir>
# Env: GATEWAY_API_VERSION (e.g. v1.6.2), ESO_CHART_VERSION (e.g. 2.11.0),
#      PROMETHEUS_OPERATOR_VERSION (e.g. v0.94.1)
set -euo pipefail

chart_dir="${1:?usage: e2e.sh <chart-dir>}"
: "${GATEWAY_API_VERSION:?}" "${ESO_CHART_VERSION:?}" "${PROMETHEUS_OPERATOR_VERSION:?}"
ns=vending

fail() {
  echo "FAIL: $*" >&2
  kubectl get all,persistentvolumeclaims,externalsecrets,servicemonitors,podmonitors,prometheusrules,networkpolicies,serviceaccounts,roles,rolebindings -n "$ns" >&2 || true
  if [ "$ns" = vending ]; then
    # The volume checks: the claims and their events, and the logs of the manual CronJob runs (absent before them).
    kubectl describe persistentvolumeclaims -n "$ns" >&2 || true
    # A pod stuck Pending or failing to start (a claim that does not bind, a nested mount) shows why in its events.
    kubectl describe pods,jobs -n "$ns" >&2 || true
    for run in cronjob-manual-run cronjob-manual-run-2; do kubectl logs -n "$ns" "job/$run" --tail=50 >&2 || true; done
  fi
  if [ "$ns" = netpol ]; then
    kubectl get pods,networkpolicies -n monitoring -o wide >&2 || true
    # The migrate Job is kept (its delete policy is before-hook-creation only, ttl 3600); kindnet enforces the policies.
    kubectl logs -n netpol job/shop-migrate --tail=50 >&2 || true
    kubectl logs -n kube-system ds/kindnet --tail=200 >&2 || true
  fi
  if [ "$ns" = rbac ]; then
    # The migrate Job is kept too: its log has the HTTP status of each of its API calls.
    kubectl logs -n rbac job/ops-migrate --tail=200 >&2 || true
  fi
  exit 1
}
pass() { echo "ok - $*"; }
# Throwaway files of the script: the umbrellas below, and the extra values of the deployment checks.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== platform prerequisites"
kubectl apply --server-side \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
# Only the CRDs of the kinds chart-base renders, no operator: the API server validates each object
# against its CRD schema, and nothing reconciles or scrapes them.
po_crds="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROMETHEUS_OPERATOR_VERSION}/example/prometheus-operator-crd"
for crd in servicemonitors podmonitors prometheusrules; do
  kubectl apply --server-side -f "${po_crds}/monitoring.coreos.com_${crd}.yaml"
done
kubectl wait --for=condition=Established --timeout=60s crd/servicemonitors.monitoring.coreos.com \
  crd/podmonitors.monitoring.coreos.com crd/prometheusrules.monitoring.coreos.com
helm install external-secrets external-secrets --repo https://charts.external-secrets.io \
  --version "$ESO_CHART_VERSION" --namespace external-secrets --create-namespace --wait --timeout 5m
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: fake
spec:
  provider:
    fake:
      data:
        - key: /sales/db-password
          value: s3cr3t
EOF
kubectl wait clustersecretstore/fake --for=condition=Ready --timeout=120s

kubectl create namespace "$ns"
kubectl label namespace "$ns" \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
# An existing Secret that components reference by name (like the ones CNPG or Strimzi create).
kubectl create secret generic e2e-shared -n "$ns" --from-literal=TOKEN=abc
# The sources of the scenarios' volumes: a Secret and a ConfigMap that nothing else references (the full scenario mounts
# them, so the Reloader annotations list them only through volumes), and two existing claims (kind's default class:
# local-path, WaitForFirstConsumer).
kubectl create secret generic e2e-files -n "$ns" --from-literal=token=files-token
kubectl create configmap e2e-rules -n "$ns" --from-literal=alerts='groups: []'
for claim in e2e-runs e2e-data; do
  kubectl apply -n "$ns" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $claim
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 64Mi}}
EOF
done
# The PriorityClass the full scenario's priorityClassName points to.
kubectl apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: e2e-high
value: 1000
globalDefault: false
preemptionPolicy: Never
description: chart-base e2e (full scenario)
EOF

install() { helm upgrade --install "$1" "$chart_dir" -n "$ns" -f "$chart_dir/ci/$1-values.yaml" --wait --timeout 5m "${@:2}"; }

echo "== deployment"
install deployment || fail "deployment scenario did not become ready under PSS restricted"
pass "API Deployment is Ready in a restricted namespace"
rs_before="$(kubectl get rs -n "$ns" -l app.kubernetes.io/instance=deployment -o name | wc -l)"
install deployment --set config.APP_MODE=api-v2 || fail "config change upgrade failed"
rs_after="$(kubectl get rs -n "$ns" -l app.kubernetes.io/instance=deployment -o name | wc -l)"
[ "$rs_after" -gt "$rs_before" ] || fail "a config change must roll the pods (checksum annotation)"
pass "a config change rolls the Deployment"
# An existing claim on the Deployment, which was installed without strategy, then two in-place strategy changes (Helm 4.3
# applies server-side): (1) RollingUpdate with maxSurge 0 and maxUnavailable 1, the remedy for a Deployment that exists
# (the API refuses a direct switch to Recreate there: measured on kube-apiserver 1.33 and 1.37); (2) Recreate, once Helm
# owns both rollingUpdate keys and can remove them. The values come from files of this script: every ci/ scenario stays
# as it is.
printf '%s\n' 'volumes: {data: {type: persistentVolumeClaim, mountPath: /data, claimName: e2e-data}}' \
  'strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}' > "$work/deployment-claim.yaml"
printf '%s\n' 'volumes: {data: {type: persistentVolumeClaim, mountPath: /data, claimName: e2e-data}}' \
  'strategy: {type: Recreate}' > "$work/deployment-recreate.yaml"
install deployment --set config.APP_MODE=api-v2 -f "$work/deployment-claim.yaml" \
  || fail "adding an existing claim with strategy RollingUpdate (maxSurge 0, maxUnavailable 1) to a Deployment installed without strategy failed"
claim="$(kubectl get deployment -n "$ns" deployment-chart-base -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName} {.status.readyReplicas}' || true)"
[ "$claim" = "e2e-data 1" ] || fail "the Deployment must mount the claim e2e-data and be Ready, got '$claim'"
pass "an existing claim is mounted after an in-place switch to RollingUpdate with maxSurge 0 (the pod is Ready)"
install deployment --set config.APP_MODE=api-v2 -f "$work/deployment-recreate.yaml" \
  || fail "the in-place switch from RollingUpdate (maxSurge 0, maxUnavailable 1) to Recreate failed"
strategy="$(kubectl get deployment -n "$ns" deployment-chart-base -o jsonpath='{.spec.strategy}' || true)"
[ "$strategy" = '{"type":"Recreate"}' ] || fail "spec.strategy must be Recreate with no rollingUpdate, got '$strategy'"
pass "the Deployment then switches to Recreate in place: spec.strategy has no rollingUpdate"

echo "== worker"
install worker || fail "worker scenario did not become ready"
kubectl get service -n "$ns" worker-chart-base > /dev/null 2>&1 && fail "worker must not have a Service"
pm="$(kubectl get podmonitor -n "$ns" worker-chart-base -o jsonpath='{.metadata.labels.release} {.spec.podMetricsEndpoints[0].port}' || true)"
[ "$pm" = "e2e metrics" ] || fail "worker must have a PodMonitor labelled release=e2e whose endpoint targets the container port 'metrics', got '$pm'"
kubectl get servicemonitor -n "$ns" worker-chart-base > /dev/null 2>&1 && fail "worker has no Service: it must not have a ServiceMonitor"
pass "worker runs without a Service; its PodMonitor's endpoint targets its named container port"

echo "== cronjob"
install cronjob || fail "cronjob scenario failed"
svc_ip="$(kubectl get service -n "$ns" deployment-chart-base -o jsonpath='{.spec.clusterIP}')"
case "$svc_ip" in ""|None) fail "the service-links check needs the deployment scenario's ClusterIP Service";; esac
kubectl create job -n "$ns" --from=cronjob/cronjob-chart-base cronjob-manual-run \
  || fail "could not create the first manual CronJob run"
kubectl wait -n "$ns" job/cronjob-manual-run --for=condition=Complete --timeout=180s \
  || fail "a CronJob run must complete (restricted pod, config, env references, envFrom with prefix, no service links)"
pass "a CronJob run sees config, env references (fieldRef, resourceFieldRef), envFrom with prefix and no service links"
# The volumes of the cronjob scenario: a run fails if the marker is already on its ephemeral volume, appends its pod name
# to /runs/pods.log on the existing claim e2e-runs, and prints that file. No check depends on a run being the first or
# the second: the schedule (*/30) can start a run between the two manual ones.
run1="$(kubectl get pods -n "$ns" -l job-name=cronjob-manual-run --field-selector=status.phase=Succeeded -o jsonpath='{.items[0].metadata.name}' || true)"
[ -n "$run1" ] || fail "the first manual run has no succeeded pod"
kubectl create job -n "$ns" --from=cronjob/cronjob-chart-base cronjob-manual-run-2 \
  || fail "could not create the second manual CronJob run"
kubectl wait -n "$ns" job/cronjob-manual-run-2 --for=condition=Complete --timeout=180s \
  || fail "the second run must complete: its ephemeral volume must not hold a marker, and the claim e2e-runs must be writable"
# The log goes to a file first: a pipeline into grep -q could fail under pipefail (SIGPIPE) when the match is not the
# last line, and here it is not (the second run's own name follows).
kubectl logs -n "$ns" job/cronjob-manual-run-2 > "$work/run2.log" || fail "could not read the second run's log"
grep -qxF "$run1" "$work/run2.log" \
  || fail "the second run must print the first run's pod name ($run1) from the claim e2e-runs: an existing claim is the same volume for every run"
pass "an existing claim keeps what one run wrote for the next; each run's ephemeral volume starts without the marker"
pvc="$run1-scratch"
owner="$(kubectl get pvc -n "$ns" "$pvc" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name} {.metadata.labels.app\.kubernetes\.io/instance}' || true)"
[ "$owner" = "Pod/$run1 cronjob" ] || fail "the ephemeral claim $pvc must be owned by its pod and carry app.kubernetes.io/instance, got '$owner'"
kubectl delete pod -n "$ns" "$run1" --wait=true || fail "could not delete the pod $run1 of the first manual run"
# Garbage collection is asynchronous: poll every 2 s for up to 120 s. --ignore-not-found makes "gone" an empty list
# with exit 0, so a kubectl error is not taken for its absence.
gone=no
for _ in $(seq 1 60); do
  left="$(kubectl get pvc -n "$ns" "$pvc" --ignore-not-found -o name)" \
    || fail "could not look up the ephemeral claim $pvc (a kubectl error, not its absence)"
  [ -z "$left" ] && { gone=yes; break; }
  sleep 2
done
[ "$gone" = yes ] || fail "the ephemeral claim $pvc must be deleted with its pod (garbage collection, polled for 120 s)"
pass "an ephemeral claim is owned by its pod, carries the instance label, and is deleted with the pod"

echo "== job (pre-deploy hook)"
install job || fail "job hook failed: it must see APP_MODE, DB_PASSWORD (ESO) and /config/migrations.yaml"
kubectl logs -n "$ns" job/job-chart-base | grep -q migrations-ok || fail "job output missing"
pass "pre-deploy Job ran with its hook ConfigMaps and ExternalSecret"
install job --set-string podAnnotations.revision=2 || fail "second deploy of a job must not hit 'field is immutable'"
pass "the Job hook is recreated on the next deploy"

echo "== full"
install full || fail "full scenario failed"
kubectl wait -n "$ns" externalsecret/full-chart-base-secrets --for=condition=Ready --timeout=120s \
  || fail "ExternalSecret did not sync"
[ "$(kubectl get secret -n "$ns" full-chart-base-secrets -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" = s3cr3t ] \
  || fail "Secret content mismatch"
kubectl get httproute -n "$ns" full-chart-base > /dev/null || fail "HTTPRoute not accepted by the API"
reload="$(kubectl get deployment -n "$ns" full-chart-base -o jsonpath='{.metadata.annotations.secret\.reloader\.stakater\.com/reload}' || true)"
[ "$reload" = "e2e-files,e2e-shared,full-chart-base-secrets" ] || fail "Reloader annotation must list the referenced and the mounted Secrets, got '$reload'"
reload="$(kubectl get deployment -n "$ns" full-chart-base -o jsonpath='{.metadata.annotations.configmap\.reloader\.stakater\.com/reload}' || true)"
[ "$reload" = "e2e-rules" ] || fail "Reloader annotation must list the mounted ConfigMap e2e-rules (nothing else references it), got '$reload'"
rollout="$(kubectl get deployment -n "$ns" full-chart-base -o jsonpath='{.spec.strategy.type} {.spec.strategy.rollingUpdate.maxSurge} {.spec.strategy.rollingUpdate.maxUnavailable} {.spec.minReadySeconds} {.spec.revisionHistoryLimit}')"
[ "$rollout" = "RollingUpdate 1 0 5 5" ] || fail "Deployment must carry strategy, minReadySeconds and revisionHistoryLimit, got '$rollout'"
pod="$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance=full -o jsonpath='{.items[0].metadata.name}')"
runtime="$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.priorityClassName} {.spec.priority} {.spec.enableServiceLinks} {.spec.dnsConfig.options[0].name}={.spec.dnsConfig.options[0].value} {.spec.hostAliases[0].ip} {.spec.hostAliases[0].hostnames[0]}')"
[ "$runtime" = "e2e-high 1000 false ndots=2 10.20.30.40 legacy-db.internal" ] \
  || fail "pod must carry priorityClassName (priority 1000), enableServiceLinks, dnsConfig and hostAliases, got '$runtime'"
fs="$(kubectl exec -n "$ns" "$pod" -- /agnhost mounttest --fs_type=/tmp/cache 2>&1 || true)"
case "$fs" in *tmpfs*) ;; *) fail "the medium: Memory emptyDir at /tmp/cache must be tmpfs, got '$fs'" ;; esac
fs="$(kubectl exec -n "$ns" "$pod" -- /agnhost mounttest --fs_type=/tmp 2>&1 || true)"
case "$fs" in *tmpfs*) fail "/tmp (the chart's emptyDir on the node's disk) must not be tmpfs, or the check above proves nothing, got '$fs'" ;; esac
token="$(kubectl exec -n "$ns" "$pod" -- cat /config/secrets/token 2>&1 || true)"
[ "$token" = files-token ] || fail "the Secret e2e-files must be readable at /config/secrets/token, a directory beneath the config-files mount, got '$token'"
# Any other failure (no sh in the image, exec refused) must not pass for a read-only mount: require the kernel's message.
if write="$(kubectl exec -n "$ns" "$pod" -- sh -c 'echo x > /config/secrets/written' 2>&1)"; then
  fail "the Secret mount at /config/secrets must be read-only: a write succeeded"
fi
case "$write" in *"Read-only file system"*) ;; *) fail "the write to the Secret mount at /config/secrets must fail with 'Read-only file system', got '$write'" ;; esac
rules="$(kubectl exec -n "$ns" "$pod" -- cat /etc/rules/alerts.yaml 2>&1 || true)"
[ "$rules" = "groups: []" ] || fail "the ConfigMap key mounted with items and subPath at /etc/rules/alerts.yaml must hold what the script wrote, got '$rules'"
pass "full: a tmpfs emptyDir beneath /tmp, a read-only Secret directory beneath the config-files mount, one ConfigMap key as one file"
sm="$(kubectl get servicemonitor -n "$ns" full-chart-base -o jsonpath='{.metadata.labels.release} {.spec.endpoints[0].port} {.spec.endpoints[0].interval}' || true)"
[ "$sm" = "e2e http 30s" ] || fail "full must have a ServiceMonitor labelled release=e2e whose endpoint targets the Service port 'http' with a 30s interval, got '$sm'"
kubectl get podmonitor -n "$ns" full-chart-base > /dev/null 2>&1 && fail "full has a Service: it must not have a PodMonitor"
rule="$(kubectl get prometheusrule -n "$ns" full-chart-base -o jsonpath='{.metadata.labels.release} {.spec.groups[0].rules[0].alert}' || true)"
[ "$rule" = "e2e FullChartBaseDown" ] || fail "full must have a PrometheusRule labelled release=e2e with its alert, got '$rule'"
np="$(kubectl get networkpolicy -n "$ns" full-chart-base -o jsonpath='{.spec.policyTypes[*]} {.spec.ingress[3].from[0].ipBlock.except[0]} {.spec.egress[2].ports[1].endPort}' || true)"
[ "$np" = "Ingress Egress 10.1.0.0/16 8100" ] || fail "full must have a NetworkPolicy with both policy types, its ipBlock except and its endPort, got '$np'"
role="$(kubectl get role -n "$ns" full-chart-base -o jsonpath='{.rules[1].resourceNames[0]} {.rules[2].resources[0]}' || true)"
[ "$role" = "full-chart-base-state pods/log" ] || fail "full must have a Role with its resourceNames and its subresource rule, got '$role'"
rb="$(kubectl get rolebinding -n "$ns" full-chart-base -o jsonpath='{.roleRef.kind}/{.roleRef.name} {.subjects[0].namespace}/{.subjects[0].name}' || true)"
[ "$rb" = "Role/full-chart-base vending/full-chart-base" ] || fail "full must have a RoleBinding of its Role to its ServiceAccount, got '$rb'"
rb="$(kubectl get rolebinding -n "$ns" full-chart-base.view -o jsonpath='{.roleRef.kind}/{.roleRef.name} {.subjects[0].namespace}/{.subjects[0].name}' || true)"
[ "$rb" = "ClusterRole/view vending/full-chart-base" ] || fail "full must have a RoleBinding to the ClusterRole view for its ServiceAccount, got '$rb'"
kubectl get hpa,pdb,ingress -n "$ns" -l app.kubernetes.io/instance=full
pass "full scenario: ExternalSecret synced, HTTPRoute/HPA/PDB/Ingress/ServiceMonitor/PrometheusRule/NetworkPolicy/Role/RoleBindings accepted, rollout and pod runtime knobs applied"

echo "== port-names"
install port-names || fail "port-names scenario failed to install"
svc="$(kubectl get service -n "$ns" port-names-chart-base -o jsonpath='{.spec.ports[0].name} {.spec.ports[0].targetPort}' || true)"
[ "$svc" = "on on" ] || fail "the Service port name and targetPort must be the string 'on', got '$svc'"
ctr="$(kubectl get deployment -n "$ns" port-names-chart-base -o jsonpath='{.spec.template.spec.containers[0].ports[0].name}' || true)"
[ "$ctr" = "on" ] || fail "the container port name must be the string 'on', got '$ctr'"
ing="$(kubectl get ingress -n "$ns" port-names-chart-base -o jsonpath='{.spec.rules[0].http.paths[0].backend.service.port.name}' || true)"
[ "$ing" = "on" ] || fail "the Ingress backend port name must be the string 'on', got '$ing'"
smp="$(kubectl get servicemonitor -n "$ns" port-names-chart-base -o jsonpath='{.spec.endpoints[0].port}' || true)"
[ "$smp" = "on" ] || fail "the ServiceMonitor endpoint must target the Service port 'on', got '$smp'"
pass "port names that YAML 1.1 reads as booleans reach the API server as strings: Service, container, Ingress backend, ServiceMonitor"

echo "== networkpolicy (an umbrella of three components under a namespace default-deny)"
# kindnet enforces NetworkPolicy, but it fails open, and skips enforcement with only a log line when
# its controller cannot start: an allow check alone would pass without enforcement, so a deny check
# comes first. agnhost connect reports a dropped connection as TIMEOUT and a port where nothing
# listens as REFUSED; a DNS error never counts as either.
# probe allow|deny <namespace> <pod> <host:port>: polls every second for up to 10 s until the
# result is the expected one, with a 3 s timeout per attempt (as Kubernetes' own NetworkPolicy e2e).
probe() {
  local expect="$1" from_ns="$2" from="$3" to="$4" out got deadline=$((SECONDS + 10))
  while :; do
    if out="$(kubectl exec -n "$from_ns" "$from" -- /agnhost connect "$to" --timeout=3s 2>&1)"; then
      got=allow
    else
      case "$out" in
        *REFUSED*) got=allow ;;
        *TIMEOUT*) got=deny ;;
        *) got="error: $out" ;;
      esac
    fi
    [ "$got" = "$expect" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  echo "probe $from_ns/$from -> $to: expected $expect, got $got" >&2
  return 1
}
ns=netpol   # fail() lists this namespace from here on
kubectl create namespace "$ns"
kubectl label namespace "$ns" \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
kubectl apply -n "$ns" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
# A namespace without policies, standing for Prometheus' namespace: a client, and a server for web.
kubectl create namespace monitoring
kubectl run probe -n monitoring --image=registry.k8s.io/e2e-test-images/agnhost:2.66.1 --restart=Never \
  -- netexec --http-port=8080
kubectl wait -n monitoring pod/probe --for=condition=Ready --timeout=120s
probe_ip="$(kubectl get pod -n monitoring probe -o jsonpath='{.status.podIP}')"
# An empty IP would make the allow check below dial the client itself, where api's netexec listens: a false pass.
[ -n "$probe_ip" ] || fail "the monitoring probe pod has no IP"

# A throwaway umbrella, like alias-contract.sh: the chart copied next to it, a relative file:// path.
mkdir -p "$work/chart-base" "$work/shop/templates"
cp -r "$chart_dir"/Chart.yaml "$chart_dir"/values.yaml "$chart_dir"/values.schema.json "$chart_dir"/templates "$work/chart-base/"
cat > "$work/shop/Chart.yaml" <<'EOF'
apiVersion: v2
name: shop
version: 0.1.0
dependencies:
  - {name: chart-base, version: ">=0.0.0-0", repository: "file://../chart-base", alias: api}
  - {name: chart-base, version: ">=0.0.0-0", repository: "file://../chart-base", alias: web}
  - {name: chart-base, version: ">=0.0.0-0", repository: "file://../chart-base", alias: migrate}
EOF
echo "chart-base NetworkPolicy e2e umbrella" > "$work/shop/templates/NOTES.txt"
cat > "$work/shop/values.yaml" <<'EOF'
api:
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  args: ["netexec", "--http-port=8080"]
  ports:
    - {name: http, containerPort: 8080}
    - {name: metrics, containerPort: 9090}   # nothing listens: an allowed connection is REFUSED
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 64Mi}}
  probes:
    readiness: {httpGet: {path: /healthz, port: http}}
  metrics: {enabled: true, port: metrics}
  networkPolicy:
    enabled: true
    ingress:
      fromComponents: [web]                  # web reaches http and metrics
      metricsFromNamespaces: [monitoring]    # the monitoring namespace reaches only metrics
web:
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  args: ["netexec", "--http-port=8080"]
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 64Mi}}
  networkPolicy:
    enabled: true                            # no ingress source: only its node reaches it
    egress:
      enabled: true                          # the cluster DNS (the default) and api, nothing else
      toComponents: [api]
migrate:
  workload: {type: job}
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  # The cluster DNS by name and over TCP: only its own policy, a hook created before it, allows it. The
  # retries cover the CNI's delay in programming that policy (the API cannot tell when it is enforced).
  command:
    - sh
    - -c
    - >-
      i=0; until /agnhost connect kube-dns.kube-system.svc.cluster.local:53 --timeout=3s;
      do i=$((i+1)); [ "$i" -lt 20 ] || exit 1; sleep 1; done; echo dns-ok
  ports: []
  resources: {requests: {cpu: 10m, memory: 16Mi}}
  job: {phase: pre-deploy, backoffLimit: 0, activeDeadlineSeconds: 120}
  networkPolicy:
    enabled: true
    egress:
      enabled: true                          # the cluster DNS only
EOF
helm dependency update "$work/shop" > /dev/null
helm upgrade --install shop "$work/shop" -n "$ns" --wait --timeout 5m \
  || fail "the umbrella did not install (if the migrate Job failed: under the default-deny, it reaches the cluster DNS only through its own NetworkPolicy, a hook created before it; see its log below)"

probe deny monitoring probe shop-web.netpol.svc.cluster.local:8080 \
  || fail "NetworkPolicy is not enforced: web allows no ingress source, yet another namespace reached it (kindnet fails open: the allow checks below would pass without enforcement)"
pass "NetworkPolicy is enforced: another namespace cannot reach web (neither web's policy nor the default-deny allows a source)"
kubectl logs -n "$ns" job/shop-migrate | grep -q dns-ok || fail "the migrate Job did not log dns-ok"
kubectl get networkpolicy -n "$ns" shop-migrate > /dev/null 2>&1 \
  && fail "the migrate Job's NetworkPolicy is a hook with hook-succeeded: it must be gone once the phase succeeded"
pass "the pre-deploy Job reached the cluster DNS under the default-deny: its NetworkPolicy, a hook of its phase, existed before it ran, and is deleted after"
probe allow "$ns" deploy/shop-web shop-api:8080 \
  || fail "web must reach api's http port: DNS by Service name, web's egress toComponents [api], api's ingress fromComponents [web]"
pass "a sibling reaches a declared port by Service name (DNS egress, toComponents, fromComponents)"
probe deny "$ns" deploy/shop-web "$probe_ip:8080" || fail "no rule of web's policy may allow a destination it does not list"
pass "web's rules allow no destination they do not list"
probe allow monitoring probe shop-api.netpol.svc.cluster.local:9090 \
  || fail "the monitoring namespace must reach api's metrics port (metricsFromNamespaces)"
probe deny monitoring probe shop-api.netpol.svc.cluster.local:8080 \
  || fail "the monitoring namespace must reach only api's metrics port, not http"
pass "the monitoring namespace reaches api's metrics port and nothing else"

# The chart's own isolation: with the default-deny deleted, only the chart's policies remain. The
# first probe also waits until the deletion is enforced.
kubectl delete networkpolicy -n "$ns" default-deny
probe allow "$ns" deploy/shop-api "$probe_ip:8080" \
  || fail "without the default-deny, api must reach another namespace: its policy isolates ingress only (egress.enabled: false)"
pass "api's ingress-only policy leaves its egress open (the default-deny is gone)"
probe deny monitoring probe shop-web.netpol.svc.cluster.local:8080 \
  || fail "web's own policy must isolate its ingress: it allows no source"
probe deny "$ns" deploy/shop-web "$probe_ip:8080" \
  || fail "web's own policy must isolate its egress: it allows only the cluster DNS and api"
pass "web's own policy isolates its ingress and its egress"

echo "== rbac (an umbrella of three components: an existing ServiceAccount, a ClusterRole, a pre-deploy Job)"
# kubectl auth can-i exits 1 for "no" and for an error alike (an identity that may not impersonate, for example), and
# answers "no", with a warning, for a resource type that does not exist and for a verb it does not know: can_i
# compares stdout and fails on either warning (a typo cannot pass as a "no"), and every "no" comes after a "yes" for
# the same ServiceAccount and resource type, so the binding is in effect when the "no" is checked. On a wrong answer
# it prints the ServiceAccount's effective rules (can-i --list); on either warning it prints the warning.
# can_i yes|no <namespace> <serviceaccount of $ns> <can-i arguments...>: polls every second for up to 10 s.
can_i() {
  local expect="$1" in_ns="$2" sa="$3" out err deadline=$((SECONDS + 10))
  shift 3
  while :; do
    out="$(kubectl auth can-i "$@" -n "$in_ns" --as="system:serviceaccount:$ns:$sa" 2> "$work/can-i.err" || true)"
    err="$(cat "$work/can-i.err")"
    case "$err" in *"doesn't have a resource type"* | *"is not a known verb"*) echo "can-i $*: $err" >&2; return 1 ;; esac
    [ "$out" = "$expect" ] && return 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  echo "can-i $* -n $in_ns as $sa: expected '$expect', got '$out' $err" >&2
  kubectl auth can-i --list -n "$in_ns" --as="system:serviceaccount:$ns:$sa" >&2 || true
  return 1
}
ns=rbac   # fail() lists this namespace from here on
kubectl create namespace "$ns"
kubectl label namespace "$ns" \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest
# An existing ServiceAccount, as a platform team creates one (for example with a cloud identity). It says no token.
kubectl apply -n "$ns" -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: e2e-existing
automountServiceAccountToken: false
EOF
mkdir -p "$work/ops/templates"
cat > "$work/ops/Chart.yaml" <<'EOF'
apiVersion: v2
name: ops
version: 0.1.0
dependencies:
  - {name: chart-base, version: ">=0.0.0-0", repository: "file://../chart-base", alias: api}
  - {name: chart-base, version: ">=0.0.0-0", repository: "file://../chart-base", alias: viewer}
  - {name: chart-base, version: ">=0.0.0-0", repository: "file://../chart-base", alias: migrate}
EOF
echo "chart-base RBAC e2e umbrella" > "$work/ops/templates/NOTES.txt"
cat > "$work/ops/values.yaml" <<'EOF'
api:
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  args: ["netexec", "--http-port=8080"]
  resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 64Mi}}
  serviceAccount:
    create: false
    name: e2e-existing                       # created above, with automountServiceAccountToken: false
    automountToken: true                     # the pod's own field wins: the token is mounted
  rbac:
    rules:
      - apiGroups: [coordination.k8s.io]     # leader election
        resources: [leases]
        verbs: [get, list, watch, create, update, patch]
      - apiGroups: [""]
        resources: [configmaps]
        resourceNames: [ops-api-state]
        verbs: [get, update]
      - apiGroups: [""]
        resources: [pods/log]                # a subresource, not the pods themselves
        verbs: [get]
viewer:
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  args: ["pause"]
  ports: []
  service: {enabled: false}
  resources: {requests: {cpu: 10m, memory: 16Mi}}
  serviceAccount: {automountToken: true}     # the chart creates ops-viewer
  rbac:
    clusterRoles: [view]                     # a RoleBinding ops-viewer.view, in this namespace only
migrate:
  workload: {type: job}
  image: {repository: registry.k8s.io/e2e-test-images/agnhost, tag: "2.66.1"}
  # Lists the namespace's ConfigMaps with its own token: only its Role and RoleBinding, hooks created before it,
  # allow it. The retries cover the authorizer's delay in seeing a new binding; each attempt logs its HTTP status
  # and, when curl itself fails, curl's error (-S). curl gives up after 3 s (--max-time), so the 20 attempts and
  # the 19 sleeps between them take about 20 x 3 + 19 x 1 = 79 s at most, of the Job's 120 s (activeDeadlineSeconds):
  # the script gives up by itself and its log stays, instead of the deadline deleting the pod while a call hangs.
  command:
    - sh
    - -c
    - >-
      d=/var/run/secrets/kubernetes.io/serviceaccount; i=0;
      until code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' --cacert "$d/ca.crt" -H "Authorization: Bearer $(cat "$d/token")"
      "https://kubernetes.default.svc/api/v1/namespaces/$(cat "$d/namespace")/configmaps");
      echo "list configmaps: HTTP $code"; [ "$code" = 200 ];
      do i=$((i+1)); [ "$i" -lt 20 ] || exit 1; sleep 1; done; echo rbac-ok
  ports: []
  resources: {requests: {cpu: 10m, memory: 16Mi}}
  serviceAccount: {automountToken: true}     # the chart creates ops-migrate, a hook like the Role and RoleBinding
  rbac:
    rules:
      - apiGroups: [""]
        resources: [configmaps]
        verbs: [list]
  job: {phase: pre-deploy, backoffLimit: 0, activeDeadlineSeconds: 120}
EOF
helm dependency update "$work/ops" > /dev/null
helm upgrade --install ops "$work/ops" -n "$ns" --wait --timeout 5m \
  || fail "the umbrella did not install (if the migrate Job failed: it lists ConfigMaps with its own token, which only its Role and RoleBinding, hooks created before it, allow; its log below has the HTTP status of each attempt)"

kubectl logs -n "$ns" job/ops-migrate | grep -q rbac-ok || fail "the migrate Job did not log rbac-ok"
# The Job's ServiceAccount, Role and RoleBinding are hooks with hook-succeeded. --ignore-not-found makes "gone" an
# empty list with exit 0, so a kubectl error is not taken for their absence.
left="$(kubectl get serviceaccount,role,rolebinding -n "$ns" ops-migrate --ignore-not-found -o name)" \
  || fail "could not look up the migrate Job's ServiceAccount, Role and RoleBinding (a kubectl error, not their absence)"
[ -z "$left" ] \
  || fail "the migrate Job's ServiceAccount, Role and RoleBinding are hooks with hook-succeeded: they must be gone once the phase succeeded, found: $(printf '%s' "$left" | tr '\n' ' ')"
pass "the pre-deploy Job listed ConfigMaps with its own token: its Role and RoleBinding, hooks of its phase, existed before it ran, and are deleted after"
can_i yes "$ns" e2e-existing get pods --subresource=log || fail "api's rule on pods/log must allow reading pod logs"
can_i no "$ns" e2e-existing get pods || fail "api's rule on the subresource pods/log must not allow the pods themselves"
can_i yes "$ns" e2e-existing create leases.coordination.k8s.io || fail "api's lease rule must allow create"
can_i no "$ns" e2e-existing delete leases.coordination.k8s.io || fail "api's lease rule lists no delete"
can_i yes "$ns" e2e-existing get configmaps/ops-api-state || fail "api's resourceNames rule must allow its own ConfigMap"
can_i no "$ns" e2e-existing get configmaps/ops-api-other || fail "api's resourceNames rule must allow no other ConfigMap"
pass "api's rules are bound to the existing ServiceAccount it names: a subresource without its parent, the listed verbs only, the listed names only"
can_i yes "$ns" ops-viewer list pods || fail "viewer's RoleBinding to the ClusterRole view must allow listing pods"
can_i no "$ns" ops-viewer create pods || fail "the ClusterRole view must not allow creating pods"
can_i no default ops-viewer list pods || fail "viewer's RoleBinding must grant view in its own namespace only"
pass "viewer's RoleBinding to the ClusterRole view grants view in the release namespace, and nothing more"

pod="$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance=ops,app.kubernetes.io/name=api -o jsonpath='{.items[0].metadata.name}' || true)"
[ -n "$pod" ] || fail "api has no pod in $ns"
spec="$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.serviceAccountName} {.spec.automountServiceAccountToken} {.spec.volumes[*].name}' || true)"
case "$spec" in
  "e2e-existing true "*kube-api-access-*) ;;
  *) fail "api's pod must run as e2e-existing with the token mounted (a kube-api-access volume), got '$spec'" ;;
esac
[ "$(kubectl get serviceaccount -n "$ns" e2e-existing -o jsonpath='{.automountServiceAccountToken}')" = false ] \
  || fail "the existing ServiceAccount must still say automountServiceAccountToken: false"
kubectl get serviceaccount -n "$ns" ops-api > /dev/null 2>&1 \
  && fail "api names an existing ServiceAccount: the chart must not create ops-api"
pass "api's pod runs as the existing ServiceAccount, with the token mounted although the ServiceAccount says false (the pod's field wins)"
# api_call <path>: the HTTP status of a GET to the API server from api's pod, with the pod's own token. The call
# lasts at most 10 s (--max-time), and curl's own error (-S) reaches this script's stderr.
api_call() {
  # shellcheck disable=SC2016 # expanded by the pod's shell, not this one
  kubectl exec -n "$ns" "$pod" -- sh -c 'd=/var/run/secrets/kubernetes.io/serviceaccount; curl -sS --max-time 10 -o /dev/null -w "%{http_code}" --cacert "$d/ca.crt" -H "Authorization: Bearer $(cat "$d/token")" "https://kubernetes.default.svc$1"' sh "$1"
}
code="$(api_call "/apis/coordination.k8s.io/v1/namespaces/$ns/leases" || true)"
[ "$code" = 200 ] || fail "api's pod must list leases with its own token (its Role allows it), got HTTP '$code'"
code="$(api_call "/api/v1/namespaces/$ns/secrets" || true)"
[ "$code" = 403 ] || fail "api's pod must be forbidden to list Secrets with its own token (no rule allows it), got HTTP '$code'"
pass "api's pod calls the API with its own token: 200 for what its Role allows, 403 for what it does not"

echo "e2e: all checks passed"
