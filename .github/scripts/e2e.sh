#!/usr/bin/env bash
# Real install of every ci/ scenario on the current kube context (a kind cluster in CI):
# namespace enforcing Pod Security "restricted", Gateway API CRDs, External Secrets Operator
# with the fake provider, Prometheus Operator CRDs (no operator). Usage: e2e.sh <chart-dir>
# Env: GATEWAY_API_VERSION (e.g. v1.6.2), ESO_CHART_VERSION (e.g. 2.11.0),
#      PROMETHEUS_OPERATOR_VERSION (e.g. v0.94.1)
set -euo pipefail

chart_dir="${1:?usage: e2e.sh <chart-dir>}"
: "${GATEWAY_API_VERSION:?}" "${ESO_CHART_VERSION:?}" "${PROMETHEUS_OPERATOR_VERSION:?}"
ns=vending

fail() {
  echo "FAIL: $*" >&2
  kubectl get all,externalsecrets,servicemonitors,podmonitors,prometheusrules -n "$ns" >&2 || true
  exit 1
}
pass() { echo "ok - $*"; }

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
kubectl create job -n "$ns" --from=cronjob/cronjob-chart-base cronjob-manual-run
kubectl wait -n "$ns" job/cronjob-manual-run --for=condition=Complete --timeout=180s \
  || fail "a CronJob run must complete (restricted pod, config, env references, envFrom with prefix, no service links)"
pass "a CronJob run sees config, env references (fieldRef, resourceFieldRef), envFrom with prefix and no service links"

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
reload="$(kubectl get deployment -n "$ns" full-chart-base -o jsonpath='{.metadata.annotations.secret\.reloader\.stakater\.com/reload}')"
[ "$reload" = "e2e-shared,full-chart-base-secrets" ] || fail "Reloader annotation must list the referenced Secrets, got '$reload'"
rollout="$(kubectl get deployment -n "$ns" full-chart-base -o jsonpath='{.spec.strategy.type} {.spec.strategy.rollingUpdate.maxSurge} {.spec.strategy.rollingUpdate.maxUnavailable} {.spec.minReadySeconds} {.spec.revisionHistoryLimit}')"
[ "$rollout" = "RollingUpdate 1 0 5 5" ] || fail "Deployment must carry strategy, minReadySeconds and revisionHistoryLimit, got '$rollout'"
pod="$(kubectl get pods -n "$ns" -l app.kubernetes.io/instance=full -o jsonpath='{.items[0].metadata.name}')"
runtime="$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.priorityClassName} {.spec.priority} {.spec.enableServiceLinks} {.spec.dnsConfig.options[0].name}={.spec.dnsConfig.options[0].value} {.spec.hostAliases[0].ip} {.spec.hostAliases[0].hostnames[0]}')"
[ "$runtime" = "e2e-high 1000 false ndots=2 10.20.30.40 legacy-db.internal" ] \
  || fail "pod must carry priorityClassName (priority 1000), enableServiceLinks, dnsConfig and hostAliases, got '$runtime'"
sm="$(kubectl get servicemonitor -n "$ns" full-chart-base -o jsonpath='{.metadata.labels.release} {.spec.endpoints[0].port} {.spec.endpoints[0].interval}' || true)"
[ "$sm" = "e2e http 30s" ] || fail "full must have a ServiceMonitor labelled release=e2e whose endpoint targets the Service port 'http' with a 30s interval, got '$sm'"
kubectl get podmonitor -n "$ns" full-chart-base > /dev/null 2>&1 && fail "full has a Service: it must not have a PodMonitor"
rule="$(kubectl get prometheusrule -n "$ns" full-chart-base -o jsonpath='{.metadata.labels.release} {.spec.groups[0].rules[0].alert}' || true)"
[ "$rule" = "e2e FullChartBaseDown" ] || fail "full must have a PrometheusRule labelled release=e2e with its alert, got '$rule'"
kubectl get hpa,pdb,ingress -n "$ns" -l app.kubernetes.io/instance=full
pass "full scenario: ExternalSecret synced, HTTPRoute/HPA/PDB/Ingress/ServiceMonitor/PrometheusRule accepted, rollout and pod runtime knobs applied"

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

echo "e2e: all checks passed"
